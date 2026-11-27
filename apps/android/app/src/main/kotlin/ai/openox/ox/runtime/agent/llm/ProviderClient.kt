package ai.openox.ox.runtime.agent.llm

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.agent.AssistantAssembler
import ai.openox.ox.runtime.modelproviders.AuthKind
import ai.openox.ox.runtime.modelproviders.ModelDefinition
import ai.openox.ox.runtime.modelproviders.ProviderDefinition
import ai.openox.ox.runtime.modelproviders.WireProtocol
import ai.openox.ox.runtime.services.string
import java.io.IOException
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

class ModelRequest(
    val conversationId: Int,
    val provider: ProviderDefinition,
    val model: ModelDefinition,
    val key: String?,
    val sessionId: String,
    val effort: String?,
    val systemPrompt: String,
    val messages: List<JsonObject>,
    val tools: List<JsonObject>,
    val maxTokens: Int?,
)

class ModelFailure(message: String) : Exception(message)

class ModelTransports(private val http: OkHttpClient) {
    suspend fun stream(request: ModelRequest, emit: (JsonElement) -> Unit) {
        val assembler = AssistantAssembler(request, emit)
        val started = System.nanoTime()
        var outcome = "error"
        try {
            if (request.provider.needsKey && request.key == null) throw ModelFailure(if (request.provider.auth.kind == AuthKind.Custom) "Sign in to ${request.provider.name} in Settings" else "Add an API key for ${request.provider.name} in Settings")
            val reason = when (request.provider.api) {
                WireProtocol.ChatCompletions -> chatCompletions(request, assembler)
                WireProtocol.AnthropicMessages -> anthropicMessages(request, assembler)
                WireProtocol.Responses -> responses(request, assembler)
                WireProtocol.Gemini, WireProtocol.Web -> throw ModelFailure("${request.provider.name} is not available on this device yet")
            }
            outcome = assembler.finish(reason)
        } catch (error: ModelFailure) {
            outcome = "error"
            assembler.fail(error.message ?: "The model request failed")
        } catch (error: IOException) {
            coroutineContext.ensureActive()
            assembler.fail("Could not reach ${request.provider.name}: ${error.message ?: error.javaClass.simpleName}")
        } finally {
            if (!coroutineContext.isActive) outcome = "aborted"
            OxLog.info(
                "model.end", "provider" to request.provider.id, "model" to request.model.id, "outcome" to outcome,
                "durationMs" to (System.nanoTime() - started) / 1_000_000, "messages" to request.messages.size, "effort" to request.effort,
            )
        }
    }

    private suspend fun chatCompletions(request: ModelRequest, assembler: AssistantAssembler): String {
        val options = request.provider.options
        val body = buildJsonObject {
            put("model", request.model.wire)
            putJsonArray("messages") {
                if (request.systemPrompt.isNotEmpty()) addJsonObject {
                    put("role", "system")
                    put("content", request.systemPrompt)
                }
                request.messages.forEach { message ->
                    val role = message.string("role")
                    val text = message.blocks("text", "text")
                    when (role) {
                        "user", "system" -> addJsonObject {
                            put("role", role)
                            put("content", message.string("text") ?: text)
                        }
                        "assistant" -> {
                            val calls = message.calls()
                            if (text.isNotEmpty() || calls.isNotEmpty()) addJsonObject {
                                put("role", "assistant")
                                put("content", if (text.isEmpty()) JsonNull else JsonPrimitive(text))
                                val thinking = message.blocks("thinking", "thinking")
                                if (request.model.options.replayReasoning && thinking.isNotEmpty()) put("reasoning_content", thinking)
                                if (calls.isNotEmpty()) putJsonArray("tool_calls") {
                                    calls.forEach { call ->
                                        addJsonObject {
                                            put("id", call.string("id"))
                                            put("type", "function")
                                            putJsonObject("function") {
                                                put("name", call.string("name"))
                                                put("arguments", (call["arguments"] ?: JsonObject(emptyMap())).toString())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        "toolResult" -> addJsonObject {
                            put("role", "tool")
                            put("tool_call_id", message.string("toolCallId"))
                            put("content", text)
                        }
                        else -> Unit
                    }
                }
            }
            if (request.tools.isNotEmpty()) putJsonArray("tools") {
                request.tools.forEach { tool ->
                    addJsonObject {
                        put("type", "function")
                        putJsonObject("function") {
                            put("name", tool.string("name"))
                            put("description", tool.string("description"))
                            put("parameters", tool["parameters"] ?: JsonObject(emptyMap()))
                        }
                    }
                }
            }
            put("stream", true)
            putJsonObject("stream_options") { put("include_usage", true) }
            put(options.maxTokensField ?: "max_tokens", request.maxTokens ?: request.model.outputTokens)
            when (options.reasoningFormat) {
                "reasoning_effort" -> (request.effort ?: options.reasoningEffort)?.let { put("reasoning_effort", it) }
                "disable-reasoning" -> putJsonObject("reasoning") { put("enabled", false) }
                "disable-thinking" -> putJsonObject("thinking") { put("type", "disabled") }
                "disable-chat-template" -> putJsonObject("chat_template_kwargs") { put("enable_thinking", false) }
                "disable-qwen" -> put("enable_thinking", false)
                else -> Unit
            }
            options.extraBody.forEach { (key, value) -> put(key, value) }
        }
        var reason = "stop"
        events(request, "${request.provider.url.trimEnd('/')}/chat/completions", body) { _, chunk ->
            (chunk["error"] as? JsonObject)?.let { throw ModelFailure(it.string("message") ?: "stream error") }
            val choice = (chunk["choices"] as? JsonArray)?.firstOrNull() as? JsonObject
            val delta = choice?.get("delta") as? JsonObject
            (delta?.string("reasoning") ?: delta?.string("reasoning_content"))?.let(assembler::thinking)
            delta?.string("content")?.let(assembler::text)
            (delta?.get("tool_calls") as? JsonArray).orEmpty().filterIsInstance<JsonObject>().forEach { call ->
                val key = (call.int("index") ?: 0).toString()
                val function = call["function"] as? JsonObject
                val name = function?.string("name")
                if (name != null) assembler.call(key, call.string("id") ?: "call_${UUID.randomUUID()}", name)
                function?.string("arguments")?.let { assembler.arguments(key, it) }
            }
            when (choice?.string("finish_reason")) {
                "length" -> reason = "length"
                "error" -> throw ModelFailure("stream ended with finish_reason=error")
                else -> Unit
            }
            (chunk["usage"] as? JsonObject)?.let { usage ->
                assembler.usage(usage.int("prompt_tokens"), usage.int("completion_tokens"), (usage["prompt_tokens_details"] as? JsonObject)?.int("cached_tokens"))
            }
        }
        return reason
    }

    private suspend fun anthropicMessages(request: ModelRequest, assembler: AssistantAssembler): String {
        val body = buildJsonObject {
            put("model", request.model.wire)
            put("max_tokens", request.maxTokens ?: request.model.outputTokens)
            if (request.systemPrompt.isNotEmpty()) put("system", request.systemPrompt)
            put("messages", turns(request.messages))
            if (request.tools.isNotEmpty()) putJsonArray("tools") {
                request.tools.forEach { tool ->
                    addJsonObject {
                        put("name", tool.string("name"))
                        put("description", tool.string("description"))
                        put("input_schema", tool["parameters"] ?: JsonObject(emptyMap()))
                    }
                }
            }
            put("stream", true)
            request.provider.options.extraBody.forEach { (key, value) -> put(key, value) }
        }
        var reason = "stop"
        events(request, "${request.provider.url.trimEnd('/')}/messages", body) { _, event ->
            when (event.string("type")) {
                "message_start" -> ((event["message"] as? JsonObject)?.get("usage") as? JsonObject)?.let { usage ->
                    assembler.usage(usage.int("input_tokens"), usage.int("output_tokens"), usage.int("cache_read_input_tokens"))
                }
                "content_block_start" -> (event["content_block"] as? JsonObject)?.takeIf { it.string("type") == "tool_use" }?.let { block ->
                    assembler.call((event.int("index") ?: 0).toString(), block.string("id") ?: "toolu_${UUID.randomUUID()}", block.string("name").orEmpty())
                }
                "content_block_delta" -> (event["delta"] as? JsonObject)?.let { delta ->
                    when (delta.string("type")) {
                        "input_json_delta" -> delta.string("partial_json")?.let { assembler.arguments((event.int("index") ?: 0).toString(), it) }
                        "text_delta" -> delta.string("text")?.let(assembler::text)
                        "thinking_delta" -> delta.string("thinking")?.let(assembler::thinking)
                        "signature_delta" -> delta.string("signature")?.let(assembler::signature)
                        else -> Unit
                    }
                }
                "message_delta" -> {
                    if ((event["delta"] as? JsonObject)?.string("stop_reason") == "max_tokens") reason = "length"
                    (event["usage"] as? JsonObject)?.let { assembler.usage(null, it.int("output_tokens"), null) }
                }
                "error" -> throw ModelFailure((event["error"] as? JsonObject)?.string("message") ?: "stream error")
                else -> Unit
            }
        }
        return reason
    }

    private suspend fun responses(request: ModelRequest, assembler: AssistantAssembler): String {
        val body = buildJsonObject {
            put("model", request.model.wire)
            if (request.systemPrompt.isNotEmpty()) put("instructions", request.systemPrompt)
            put("input", buildJsonArray {
                request.messages.forEach { message ->
                    val role = message.string("role")
                    val text = message.string("text") ?: message.blocks("text", "text")
                    if (role == "toolResult") addJsonObject {
                        put("type", "function_call_output")
                        put("call_id", message.string("toolCallId"))
                        put("output", text)
                    }
                    if (role !in CONVERSATION_ROLES) return@forEach
                    if (text.isNotEmpty()) addJsonObject {
                        put("role", if (role == "assistant") "assistant" else "user")
                        putJsonArray("content") {
                            addJsonObject {
                                put("type", if (role == "assistant") "output_text" else "input_text")
                                put("text", text)
                            }
                        }
                    }
                    message.calls().forEach { call ->
                        addJsonObject {
                            put("type", "function_call")
                            put("call_id", call.string("id"))
                            put("name", call.string("name"))
                            put("arguments", (call["arguments"] ?: JsonObject(emptyMap())).toString())
                        }
                    }
                }
            })
            if (request.tools.isNotEmpty()) putJsonArray("tools") {
                request.tools.forEach { tool ->
                    addJsonObject {
                        put("type", "function")
                        put("name", tool.string("name"))
                        put("description", tool.string("description"))
                        put("parameters", tool["parameters"] ?: JsonObject(emptyMap()))
                        put("strict", false)
                    }
                }
            }
            put("stream", true)
            put("store", false)
            put("max_output_tokens", request.maxTokens ?: request.model.outputTokens)
            request.model.options.serviceTier?.let { put("service_tier", it) }
            if (request.provider.options.sessionHeader != null) put("prompt_cache_key", request.sessionId)
            (request.effort ?: request.provider.options.reasoningEffort)?.let { effort -> putJsonObject("reasoning") { put("effort", effort) } }
            request.provider.options.extraBody.forEach { (key, value) -> put(key, value) }
        }
        var reason = "stop"
        events(request, "${request.provider.url.trimEnd('/')}/responses", body) { _, event ->
            when (event.string("type")) {
                "response.output_text.delta" -> event.string("delta")?.let(assembler::text)
                "response.output_item.done" -> (event["item"] as? JsonObject)?.takeIf { it.string("type") == "function_call" }?.let { item ->
                    val id = item.string("call_id") ?: "call_${UUID.randomUUID()}"
                    assembler.call(id, id, item.string("name").orEmpty())
                    assembler.arguments(id, item.string("arguments").orEmpty())
                }
                "response.reasoning_summary_text.delta", "response.reasoning_text.delta" -> event.string("delta")?.let(assembler::thinking)
                "response.completed", "response.incomplete" -> {
                    val response = event["response"] as? JsonObject
                    if (event.string("type") == "response.incomplete") reason = "length"
                    (response?.get("usage") as? JsonObject)?.let { usage ->
                        assembler.usage(usage.int("input_tokens"), usage.int("output_tokens"), (usage["input_tokens_details"] as? JsonObject)?.int("cached_tokens"))
                    }
                }
                "response.failed" -> throw ModelFailure((((event["response"] as? JsonObject)?.get("error")) as? JsonObject)?.string("message") ?: "The response failed")
                "error" -> throw ModelFailure(event.string("message") ?: (event["error"] as? JsonObject)?.string("message") ?: "stream error")
                else -> Unit
            }
        }
        return reason
    }

    private fun turns(messages: List<JsonObject>): JsonArray {
        val turns = mutableListOf<Pair<String, MutableList<JsonObject>>>()
        fun append(role: String, block: JsonObject) {
            if (turns.lastOrNull()?.first != role) turns += role to mutableListOf()
            turns.last().second += block
        }
        messages.forEach { message ->
            val role = message.string("role")
            val text = message.string("text") ?: message.blocks("text", "text")
            if (role == "toolResult") append("user", buildJsonObject {
                put("type", "tool_result")
                put("tool_use_id", message.string("toolCallId"))
                put("content", text)
                put("is_error", (message["isError"] as? JsonPrimitive)?.booleanOrNull == true)
            })
            if (role !in CONVERSATION_ROLES) return@forEach
            val speaker = if (role == "assistant") "assistant" else "user"
            if (text.isNotEmpty()) append(speaker, buildJsonObject {
                put("type", "text")
                put("text", text)
            })
            message.calls().forEach { call ->
                append("assistant", buildJsonObject {
                    put("type", "tool_use")
                    put("id", call.string("id"))
                    put("name", call.string("name"))
                    put("input", call["arguments"] ?: JsonObject(emptyMap()))
                })
            }
        }
        return buildJsonArray {
            turns.forEach { (role, blocks) ->
                addJsonObject {
                    put("role", role)
                    put("content", JsonArray(blocks))
                }
            }
        }
    }

    private suspend fun events(request: ModelRequest, url: String, body: JsonObject, handle: (String?, JsonObject) -> Unit) {
        val provider = request.provider
        val call = http.newCall(Request.Builder().url(url).apply {
            header("Accept", "text/event-stream")
            request.key?.let { key ->
                if (provider.auth.kind == AuthKind.ApiKey) header(provider.auth.header ?: "x-api-key", key) else header("Authorization", "Bearer $key")
            }
            if (provider.api == WireProtocol.AnthropicMessages) {
                header("anthropic-version", provider.options.version ?: "2023-06-01")
                if (provider.options.beta.isNotEmpty()) header("anthropic-beta", provider.options.beta.joinToString(","))
            }
            provider.options.sessionHeader?.let { header(it, request.sessionId) }
            provider.options.headers.forEach { (name, value) -> header(name, value) }
            post(body.toString().toRequestBody(JSON_MEDIA))
        }.build())
        val response = suspendCancellableCoroutine<Response> { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = continuation.resumeWithException(e)
                override fun onResponse(call: Call, response: Response) = continuation.resume(response)
            })
        }
        withContext(Dispatchers.IO) {
            response.use {
                if (!response.isSuccessful) throw ModelFailure(failure(provider, response.code, response.body.string()))
                val source = response.body.source()
                var event: String? = null
                while (true) {
                    ensureActive()
                    val line = source.readUtf8Line() ?: break
                    when {
                        line.startsWith("event:") -> event = line.substring(6).trim()
                        line.startsWith("data:") -> {
                            val data = line.substring(5).trim()
                            if (data == "[DONE]") break
                            (runCatching { Json.parseToJsonElement(data) }.getOrNull() as? JsonObject)?.let { handle(event, it) }
                        }
                        line.isEmpty() -> event = null
                    }
                }
            }
        }
    }

    private fun failure(provider: ProviderDefinition, code: Int, body: String): String {
        val parsed = runCatching { Json.parseToJsonElement(body) }.getOrNull() as? JsonObject
        val detail = (parsed?.get("error") as? JsonObject)?.string("message") ?: parsed?.string("error") ?: parsed?.string("message")
        OxLog.warning("model.http.failed", "provider" to provider.id, "status" to code, "message" to detail)
        return "${provider.name} returned HTTP $code" + (detail?.let { ": $it" } ?: "")
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.calls(): List<JsonObject> =
        (this["content"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().filter { it.string("type") == "toolCall" }

    private fun JsonObject.blocks(type: String, field: String): String =
        (this["content"] as? JsonArray).orEmpty().mapNotNull { block -> (block as? JsonObject)?.takeIf { it.string("type") == type }?.string(field) }.joinToString("")

    private companion object {
        val JSON_MEDIA = "application/json".toMediaType()
        val CONVERSATION_ROLES = setOf("user", "assistant", "system")
    }
}
