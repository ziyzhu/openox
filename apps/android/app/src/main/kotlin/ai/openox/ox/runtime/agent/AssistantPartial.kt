package ai.openox.ox.runtime.agent

import ai.openox.ox.runtime.agent.llm.ModelFailure
import ai.openox.ox.runtime.agent.llm.ModelRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Call

class AssistantAssembler(private val request: ModelRequest, private val emit: (JsonElement) -> Unit) {
    private sealed interface Block {
        class Text(val text: StringBuilder = StringBuilder()) : Block
        class Thinking(val text: StringBuilder = StringBuilder(), var signature: String? = null) : Block
        class Call(val id: String, val name: String, val arguments: StringBuilder = StringBuilder()) : Block
    }

    private val blocks = mutableListOf<Block>()
    private val calls = mutableMapOf<String, Block.Call>()
    private var input = 0
    private var output = 0
    private var cached = 0
    private var started = false

    fun text(delta: String) {
        if (delta.isEmpty()) return
        val block = blocks.lastOrNull() as? Block.Text ?: Block.Text().also(::open)
        block.text.append(delta)
        delta("text_delta", delta)
    }

    fun thinking(delta: String) {
        if (delta.isEmpty()) return
        val block = blocks.lastOrNull() as? Block.Thinking ?: Block.Thinking().also(::open)
        block.text.append(delta)
        delta("thinking_delta", delta)
    }

    fun signature(value: String) {
        (blocks.lastOrNull() as? Block.Thinking)?.signature = value
    }

    fun call(key: String, id: String, name: String) {
        if (key in calls) return
        calls[key] = Block.Call(id, name).also(::open)
    }

    fun arguments(key: String, delta: String) {
        calls[key]?.arguments?.append(delta)
    }

    fun usage(input: Int?, output: Int?, cached: Int?) {
        input?.let { this.input = it }
        output?.let { this.output = it }
        cached?.let { this.cached = it }
    }

    fun finish(stop: String): String {
        start()
        close()
        val pending = blocks.withIndex().filter { it.value is Block.Call }
        pending.forEach { (index, block) ->
            if (arguments(block as Block.Call) == null) throw ModelFailure("The model sent invalid arguments for ${block.name}")
            emit(buildJsonObject {
                put("type", "toolcall_end")
                put("contentIndex", index)
                put("toolCall", content(block))
                put("partial", message("toolUse", null))
            })
        }
        val reason = if (pending.isNotEmpty() && stop == "stop") "toolUse" else stop
        emit(buildJsonObject {
            put("type", "done")
            put("reason", reason)
            put("message", message(reason, null))
        })
        return reason
    }

    fun fail(message: String) {
        start()
        emit(buildJsonObject {
            put("type", "error")
            put("reason", "error")
            put("error", message("error", message))
        })
    }

    private fun open(block: Block) {
        start()
        close()
        blocks += block
    }

    private fun close() {
        val index = blocks.lastIndex
        if (index < 0 || blocks[index] is Block.Call) return
        emit(buildJsonObject {
            put("type", if (blocks[index] is Block.Text) "text_end" else "thinking_end")
            put("contentIndex", index)
            put("content", "")
            put("partial", message("stop", null))
        })
    }

    private fun start() {
        if (started) return
        started = true
        emit(buildJsonObject {
            put("type", "start")
            put("partial", message("stop", null))
        })
    }

    private fun delta(type: String, delta: String) = emit(buildJsonObject {
        put("type", type)
        put("contentIndex", blocks.lastIndex)
        put("delta", delta)
        put("partial", message("stop", null))
    })

    private fun arguments(call: Block.Call): JsonObject? =
        if (call.arguments.isBlank()) JsonObject(emptyMap()) else runCatching { Json.parseToJsonElement(call.arguments.toString()) }.getOrNull() as? JsonObject

    private fun content(block: Block) = buildJsonObject {
        when (block) {
            is Block.Text -> {
                put("type", "text")
                put("text", block.text.toString())
            }
            is Block.Thinking -> {
                put("type", "thinking")
                put("thinking", block.text.toString())
                block.signature?.let { put("thinkingSignature", it) }
            }
            is Block.Call -> {
                put("type", "toolCall")
                put("id", block.id)
                put("name", block.name)
                put("arguments", arguments(block) ?: JsonObject(emptyMap()))
            }
        }
    }

    private fun message(stopReason: String, error: String?) = buildJsonObject {
        put("role", "assistant")
        putJsonArray("content") { blocks.forEach { add(content(it)) } }
        put("api", "ox-native")
        put("provider", "ox-native:${request.conversationId}")
        put("model", request.model.id)
        putJsonObject("usage") {
            put("input", input)
            put("output", output)
            put("cacheRead", cached)
            put("cacheWrite", 0)
            put("totalTokens", input + output)
            putJsonObject("cost") { COST_FIELDS.forEach { put(it, 0) } }
        }
        put("stopReason", stopReason)
        error?.let { put("errorMessage", it) }
        put("timestamp", System.currentTimeMillis())
    }

    private companion object {
        val COST_FIELDS = listOf("input", "output", "cacheRead", "cacheWrite", "total")
    }
}
