package ai.openox.ox.runtime.conversations

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.durable.AgentRuntimeException
import ai.openox.ox.runtime.files.ProfileFiles
import ai.openox.ox.runtime.services.ServiceTools
import ai.openox.ox.runtime.services.web.publicweb.WebFetch
import ai.openox.ox.runtime.vm.ExecutionBudget
import ai.openox.ox.runtime.vm.ExecutionVm
import ai.openox.ox.runtime.vm.OxFunctionError
import ai.openox.ox.runtime.vm.ToolCatalog
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

class OxTools(
    private val catalog: ToolCatalog,
    private val files: ProfileFiles,
    private val web: WebFetch,
    private val filesystem: suspend (capability: String, operation: String, arguments: JsonObject) -> JsonElement,
    private val rename: suspend (conversation: Int, title: String) -> Boolean,
    private val services: ServiceTools,
) {
    private val vm = ExecutionVm(catalog)

    suspend fun execute(conversation: Int, arguments: JsonObject): JsonObject {
        val source = (arguments["source"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        if (source.isNullOrBlank()) return result("missing 'source'", failed = true)
        if (source.length > ToolCatalog.MAX_SOURCE_CHARS) return result("'source' exceeds ${ToolCatalog.MAX_SOURCE_CHARS} characters", failed = true)
        val started = System.nanoTime()
        val calls = AtomicInteger()
        val fetches = AtomicInteger()
        val output = vm.run(source) { name, values, budget ->
            calls.incrementAndGet()
            call(conversation, name, values, fetches, budget)
        }
        val text = (output.lines + listOfNotNull(output.failure?.let { "[error] $it" })).joinToString("\n").ifEmpty { "(no output)" }
        val shown = truncated(conversation, text)
        OxLog.info(
            "tool.execute", "conversation" to conversation, "purpose" to (arguments["purpose"] as? JsonPrimitive)?.contentOrNull?.take(80),
            "sourceChars" to source.length, "calls" to calls.get(), "failed" to (output.failure != null), "outputBytes" to text.length,
            "truncated" to (shown != text), "durationMs" to (System.nanoTime() - started) / 1_000_000,
        )
        return result(shown, failed = output.failure != null)
    }

    private suspend fun call(conversation: Int, name: String, arguments: JsonObject, fetches: AtomicInteger, budget: ExecutionBudget): JsonElement = when (name) {
        "ox.web.fetch" -> {
            if (fetches.incrementAndGet() > ToolCatalog.MAX_FETCHES) throw OxFunctionError("limit_exceeded", "This execution already fetched ${ToolCatalog.MAX_FETCHES} resources")
            web.fetch(arguments)
        }
        "ox.conversation.rename" -> {
            val title = (arguments["title"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
            if (title.isEmpty() || title.length > MAX_TITLE) throw OxFunctionError("invalid_arguments", "Provide a title of at most $MAX_TITLE characters")
            buildJsonObject {
                put("renamed", rename(conversation, title))
                put("title", title)
            }
        }
        else -> {
            val operation = FILE_OPERATIONS[name]
                ?: return budget.exempt { services.call(conversation, name, arguments, budget) } ?: throw OxFunctionError("unavailable", "$name is not available on this device yet")
            val capability = files.grant(conversation, operation)
            try {
                filesystem(capability, operation, JsonObject(arguments.mapValues { (key, value) -> if (key in PATH_FIELDS) files.rooted(value) else value }))
            } catch (error: AgentRuntimeException) {
                val reported = runCatching { Json.parseToJsonElement(error.message.orEmpty()) }.getOrNull() as? JsonObject ?: throw error
                throw OxFunctionError(
                    (reported["code"] as? JsonPrimitive)?.contentOrNull ?: "failed",
                    listOfNotNull((reported["message"] as? JsonPrimitive)?.contentOrNull, (reported["recovery"] as? JsonPrimitive)?.contentOrNull).joinToString(" "),
                )
            } finally {
                files.revoke(capability)
            }
        }
    }

    private fun result(text: String, failed: Boolean) = buildJsonObject {
        putJsonArray("content") {
            addJsonObject {
                put("type", "text")
                put("text", text)
            }
        }
        put("isError", failed)
    }

    private suspend fun truncated(conversation: Int, text: String): String {
        val budget = ToolCatalog.MAX_OUTPUT_TOKENS * ToolCatalog.CHARACTERS_PER_TOKEN
        if (text.length <= budget) return text
        val headEnd = (budget / 2).let { if (text[it - 1].isHighSurrogate()) it - 1 else it }
        val tailStart = (text.length - (budget - budget / 2)).let { if (text[it].isLowSurrogate()) it + 1 else it }
        val saved = runCatching { files.keep(conversation, text) }.onFailure { if (it is CancellationException) throw it }
        saved.exceptionOrNull()?.let { OxLog.error("tool.output.save.failed", "conversation" to conversation, "outputChars" to text.length, "error" to it.message) }
        return catalog.truncation(
            head = text.substring(0, headEnd), tail = text.substring(tailStart),
            originalTokens = tokens(text.length), totalLines = text.count { it == '\n' } + 1, truncatedTokens = tokens(tailStart - headEnd), saved = saved,
        )
    }

    private fun tokens(characters: Int) = (characters + ToolCatalog.CHARACTERS_PER_TOKEN - 1) / ToolCatalog.CHARACTERS_PER_TOKEN

    private companion object {
        const val MAX_TITLE = 50
        val PATH_FIELDS = setOf("path", "from", "to")
        val FILE_OPERATIONS = mapOf(
            "ox.fs.stat" to "stat", "ox.fs.ls" to "list", "ox.fs.read" to "read", "ox.fs.write" to "write", "ox.fs.edit" to "edit",
            "ox.fs.mkdir" to "mkdir", "ox.fs.move" to "move", "ox.fs.copy" to "copy", "ox.fs.find" to "glob", "ox.fs.grep" to "grep",
        )
    }
}
