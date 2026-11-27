package ai.openox.ox.runtime.vm

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.durable.AgentRuntimeException
import android.content.res.AssetManager
import com.dokar.quickjs.binding.function
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

class ToolCatalog private constructor(
    val names: List<String>,
    val help: JsonObject,
    val tool: JsonObject,
    private val truncation: String,
    private val unsavedTruncation: String,
) {
    fun truncation(head: String, tail: String, originalTokens: Int, totalLines: Int, truncatedTokens: Int, saved: Result<String>): String {
        val values = mapOf(
            HEAD_MARKER to head, TAIL_MARKER to tail, ORIGINAL_TOKENS_MARKER to "$originalTokens", TOTAL_LINES_MARKER to "$totalLines",
            TRUNCATED_TOKENS_MARKER to "$truncatedTokens", PATH_MARKER to saved.getOrNull().orEmpty(),
            SAVE_ERROR_MARKER to saved.exceptionOrNull()?.message.orEmpty(),
        )
        return MARKERS.replace(if (saved.isSuccess) truncation else unsavedTruncation) { values.getValue(it.value) }
    }

    companion object {
        const val EXECUTE = "execute"
        const val TIMEOUT_SECONDS = 60
        const val MAX_OUTPUT_TOKENS = 10_000
        const val CHARACTERS_PER_TOKEN = 4
        const val MAX_FETCHES = 8
        const val MAX_SOURCE_CHARS = 100_000
        private const val PATH_MARKER = "__OX_OUTPUT_PATH__"
        private const val SAVE_ERROR_MARKER = "__OX_OUTPUT_SAVE_ERROR__"
        private const val HEAD_MARKER = "__OX_OUTPUT_HEAD__"
        private const val TAIL_MARKER = "__OX_OUTPUT_TAIL__"
        private const val ORIGINAL_TOKENS_MARKER = "999001"
        private const val TOTAL_LINES_MARKER = "999002"
        private const val TRUNCATED_TOKENS_MARKER = "999003"
        private val MARKERS = Regex(listOf(PATH_MARKER, SAVE_ERROR_MARKER, HEAD_MARKER, TAIL_MARKER, ORIGINAL_TOKENS_MARKER, TOTAL_LINES_MARKER, TRUNCATED_TOKENS_MARKER).joinToString("|"))
        private const val MEMORY_BYTES = 64L * 1024 * 1024
        private val FUNCTIONS = listOf(
            "ox.fs.stat", "ox.fs.ls", "ox.fs.read", "ox.fs.write", "ox.fs.edit", "ox.fs.mkdir", "ox.fs.move", "ox.fs.copy", "ox.fs.find", "ox.fs.grep",
            "ox.web.fetch", "ox.conversation.rename",
            "ox.web.browser.newPage", "ox.web.browser.goto", "ox.web.browser.reload", "ox.web.browser.goBack", "ox.web.browser.goForward",
            "ox.web.browser.waitForURL", "ox.web.browser.frames", "ox.web.browser.evaluate", "ox.web.browser.snapshot", "ox.web.browser.showPage",
            "ox.web.browser.close", "ox.web.browser.pages",
            "ox.service.list", "ox.service.inspect", "ox.service.validate", "ox.service.attach", "ox.service.detach", "ox.service.listAttached",
            "ox.service.invoke", "ox.repository.list",
        )
        private val CONTRACT_FILES = listOf("fs", "web", "conversation", "service", "repository")

        suspend fun load(assets: AssetManager): ToolCatalog {
            val started = System.nanoTime()
            fun asset(name: String) = assets.open("agent/$name").bufferedReader().use { it.readText() }
            val contracts = buildJsonObject {
                val all = CONTRACT_FILES.flatMap { Json.parseToJsonElement(asset("contracts/$it.json")).jsonObject.entries }.associate { it.key to it.value }
                FUNCTIONS.forEach { name -> put(name, all[name] ?: throw AgentRuntimeException("Missing contract for $name")) }
            }
            val facts = buildJsonObject {
                put("timeoutSeconds", TIMEOUT_SECONDS)
                put("maxOutputTokens", MAX_OUTPUT_TOKENS)
                put("maxFetches", MAX_FETCHES)
                put("path", PATH_MARKER)
                put("saveError", SAVE_ERROR_MARKER)
                put("head", HEAD_MARKER)
                put("tail", TAIL_MARKER)
                put("originalTokens", ORIGINAL_TOKENS_MARKER.toInt())
                put("totalLines", TOTAL_LINES_MARKER.toInt())
                put("truncatedTokens", TRUNCATED_TOKENS_MARKER.toInt())
            }
            val generated = JavaScript.run("ox-prompts-js", 30.seconds, MEMORY_BYTES) { engine ->
                engine.function("__oxContracts") { contracts.toString() }
                engine.function("__oxFacts") { facts.toString() }
                engine.evaluate<Any?>(asset("prompts.js"), "ox-trusted://prompts.js")
                Json.parseToJsonElement(engine.evaluate<String>(GENERATE, "ox-trusted://catalog.js")).jsonObject
            }
            val description = (generated["description"] as? JsonPrimitive)?.contentOrNull ?: throw AgentRuntimeException("Tool guidance is unavailable")
            OxLog.info("tools.catalog.loaded", "functions" to FUNCTIONS.size, "descriptionChars" to description.length, "durationMs" to (System.nanoTime() - started) / 1_000_000)
            return ToolCatalog(
                names = FUNCTIONS,
                help = generated["help"] as? JsonObject ?: JsonObject(emptyMap()),
                tool = buildJsonObject {
                    put("name", EXECUTE)
                    put("description", description)
                    putJsonObject("parameters") {
                        put("type", "object")
                        putJsonObject("properties") {
                            putJsonObject("purpose") {
                                put("type", "string")
                                put("description", "Short (<10 words) description of this execution.")
                                put("minLength", 1)
                                put("maxLength", 80)
                            }
                            putJsonObject("source") {
                                put("type", "string")
                                put("description", "JavaScript snippet body. Use `await`; emit text with `console.log` or `return`.")
                                put("minLength", 1)
                                put("maxLength", MAX_SOURCE_CHARS)
                            }
                        }
                        putJsonArray("required") {
                            add("purpose")
                            add("source")
                        }
                        put("additionalProperties", false)
                    }
                },
                truncation = (generated["truncation"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                unsavedTruncation = (generated["unsavedTruncation"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
            )
        }

        private val GENERATE = """
            (() => {
              const contracts = JSON.parse(__oxContracts());
              const facts = JSON.parse(__oxFacts());
              const truncationFacts = { head: facts.head, tail: facts.tail, originalTokens: facts.originalTokens, totalLines: facts.totalLines, truncatedTokens: facts.truncatedTokens };
              const names = Object.keys(contracts);
              const line = text => text.split(/\s+/).filter(Boolean).join(' ');
              const compact = description => {
                const text = line(description);
                const usage = [': `', ': await ', ' before calling await ', ' with `{'].map(marker => text.indexOf(marker)).filter(index => index >= 0);
                const endings = ['. ', '? ', '! '].map(marker => text.indexOf(marker)).filter(index => index >= 0);
                const summary = usage.length ? text.slice(0, Math.min(...usage)) : endings.length ? text.slice(0, Math.min(...endings) + 1) : text;
                return /[.?!]$/.test(summary) ? summary : summary + '.';
              };
              const namespaces = [...new Set(names.map(name => name.split('.')[1]))];
              const catalog = [
                ...namespaces.map(namespace => 'ox.' + namespace + ' — ' + OxPrompts.guidanceText('namespace.' + namespace)),
                '',
                ...names.map(name => name + ' — ' + compact(contracts[name].description)).sort(),
              ].join('\n');
              const help = {};
              for (const name of names) {
                const contract = contracts[name];
                help[name] = [name, line(contract.description), 'input: ' + JSON.stringify(contract.inputSchema)]
                  .concat(contract.outputSchema ? ['output: ' + JSON.stringify(contract.outputSchema)] : []).join('\n\n');
              }
              for (const namespace of namespaces) {
                help['ox.' + namespace] = ['ox.' + namespace]
                  .concat(names.filter(name => name.startsWith('ox.' + namespace + '.')).map(name => name + ' — ' + compact(contracts[name].description)).sort()).join('\n');
              }
              help.ox = catalog;
              return JSON.stringify({
                description: OxPrompts.executeGuidance({
                  catalog, timeoutSeconds: facts.timeoutSeconds, maxOutputTokens: facts.maxOutputTokens,
                  maxFetches: facts.maxFetches, maxTransientAttachments: 0, canCancelLoops: true, functions: names,
                }),
                help,
                truncation: OxPrompts.outputTruncation({ ...truncationFacts, path: facts.path, saveError: null }),
                unsavedTruncation: OxPrompts.outputTruncation({ ...truncationFacts, path: null, saveError: facts.saveError }),
              });
            })()
        """.trimIndent()
    }
}
