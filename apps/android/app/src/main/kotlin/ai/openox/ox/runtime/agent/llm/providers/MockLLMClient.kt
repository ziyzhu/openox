package ai.openox.ox.runtime.agent.llm.providers

import ai.openox.ox.runtime.services.string
import ai.openox.ox.runtime.vm.ToolCatalog
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

object MockModel {
    const val ID = "mock"
    const val NAME = "Mock"

    suspend fun stream(conversationId: Int, messages: List<JsonObject>, emit: (JsonElement) -> Unit) {
        val last = messages.lastOrNull()
        val prompt = messages.lastOrNull { it.string("role") == "user" }.text().trim()
        emit(buildJsonObject {
            put("type", "start")
            put("partial", message(conversationId, null))
        })
        if (last?.string("role") != "toolResult" && prompt.startsWith(SCRIPT_PREFIX)) {
            val call = buildJsonObject {
                put("type", "toolCall")
                put("id", "call_${UUID.randomUUID().toString().take(8)}")
                put("name", ToolCatalog.EXECUTE)
                putJsonObject("arguments") {
                    put("purpose", "Run the mock script")
                    put("source", prompt.removePrefix(SCRIPT_PREFIX))
                }
            }
            delay(SCRIPT_DELAY_MS)
            emit(buildJsonObject {
                put("type", "toolcall_end")
                put("contentIndex", 0)
                put("toolCall", call)
                put("partial", message(conversationId, null, call))
            })
            emit(buildJsonObject {
                put("type", "done")
                put("reason", "toolUse")
                put("message", message(conversationId, null, call))
            })
            return
        }
        val reply = when {
            last?.string("role") == "toolResult" -> "(mock) The script returned:\n\n```\n${last.text()}\n```"
            prompt == "1" -> LONG
            prompt == "10" -> MARKDOWN
            else -> "(mock) Ox is running on this Android device. You said: $prompt"
        }
        var text = ""
        WORD.findAll(reply).forEach { match ->
            delay(WORD_DELAY_MS)
            text += match.value
            emit(buildJsonObject {
                put("type", "text_delta")
                put("contentIndex", 0)
                put("delta", match.value)
                put("partial", message(conversationId, text))
            })
        }
        emit(buildJsonObject {
            put("type", "text_end")
            put("contentIndex", 0)
            put("content", "")
            put("partial", message(conversationId, text))
        })
        emit(buildJsonObject {
            put("type", "done")
            put("reason", "stop")
            put("message", message(conversationId, text))
        })
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject?.text(): String =
        (this?.get("content") as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.takeIf { block -> block.string("type") == "text" }?.string("text") }.joinToString("")

    private fun message(conversationId: Int, text: String?, call: JsonObject? = null) = buildJsonObject {
        put("role", "assistant")
        putJsonArray("content") {
            if (text != null) addJsonObject {
                put("type", "text")
                put("text", text)
            }
            if (call != null) add(call)
        }
        put("api", "ox-native")
        put("provider", "ox-native:$conversationId")
        put("model", ID)
        putJsonObject("usage") {
            USAGE_FIELDS.forEach { put(it, 0) }
            putJsonObject("cost") { COST_FIELDS.forEach { put(it, 0) } }
        }
        put("stopReason", if (call != null) "toolUse" else "stop")
        put("timestamp", System.currentTimeMillis())
    }

    private const val WORD_DELAY_MS = 25L
    private const val SCRIPT_DELAY_MS = 300L
    private const val SCRIPT_PREFIX = "js "
    private val WORD = Regex("""\S+\s*""")
    private val USAGE_FIELDS = listOf("input", "output", "cacheRead", "cacheWrite", "totalTokens")
    private val COST_FIELDS = listOf("input", "output", "cacheRead", "cacheWrite", "total")
    private val LONG = List(120) { "Lorem ipsum dolor sit amet, consectetur adipiscing elit." }.joinToString(" ")
    private val MARKDOWN = """
        # Heading

        A paragraph with **bold**, *italic* and `code`.

        - first item
        - second item

        1. ordered one
        2. ordered two

        ```kotlin
        val answer = 42
        ```

        > A blockquote, for good measure.
    """.trimIndent()
}
