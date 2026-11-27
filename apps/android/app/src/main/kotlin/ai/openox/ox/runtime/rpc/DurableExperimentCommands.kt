package ai.openox.ox.runtime.rpc

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.agent.llm.providers.MockModel
import ai.openox.ox.runtime.durable.AgentDatabase
import ai.openox.ox.runtime.durable.AgentRuntime
import ai.openox.ox.runtime.durable.AgentRuntimeException
import android.content.Context
import java.io.File
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

object AgentProbe {
    suspend fun run(context: Context, prompt: String) {
        val directory = File(context.noBackupFilesDir, "agent-probe")
        directory.deleteRecursively()
        val events = mutableListOf<String>()
        val runtime = AgentRuntime(
            bundle = { context.assets.open("agent/harness.js").bufferedReader().use { it.readText() } },
            database = AgentDatabase(File(directory, "state.sqlite")),
        ) { method, params, stream ->
            when (method) {
                "agentEvents" -> {
                    (params["events"] as? JsonArray).orEmpty().forEach { event ->
                        (event.jsonObject["type"] as? JsonPrimitive)?.contentOrNull?.let(events::add)
                    }
                    JsonNull
                }
                "nativeModel" -> {
                    val conversation = (params["conversationID"] as? JsonPrimitive)?.intOrNull ?: throw AgentRuntimeException("Native conversation is not attached")
                    MockModel.stream(conversation, (params["messages"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>(), stream)
                    JsonNull
                }
                else -> throw AgentRuntimeException("Unavailable native capability $method")
            }
        }
        val started = System.nanoTime()
        try {
            runtime.command(buildJsonObject {
                put("action", "open")
                put("profileID", UUID.randomUUID().toString().uppercase())
            })
            val created = runtime.command(buildJsonObject {
                put("action", "conversationCreate")
                putJsonObject("metadata") {}
            })
            val conversation = (created.jsonObject["reference"]?.jsonObject?.get("conversationID") as JsonPrimitive).intOrNull
                ?: throw AgentRuntimeException("Conversation creation did not return its identity")
            runtime.command(buildJsonObject {
                put("action", "attach")
                put("conversationID", conversation)
                put("config", configuration())
            })
            val opened = (System.nanoTime() - started) / 1_000_000
            val result = runtime.command(buildJsonObject {
                put("action", "run")
                put("conversationID", conversation)
                put("requestID", UUID.randomUUID().toString())
                putJsonArray("content") {
                    addJsonObject {
                        put("type", "text")
                        put("text", prompt)
                    }
                }
            }).jsonObject
            val status = (result["receipt"]?.jsonObject?.get("status") as? JsonPrimitive)?.contentOrNull
            val reply = (result["messages"] as? JsonArray).orEmpty().lastOrNull()?.let(::textOf)
            OxLog.info(
                "agent.probe.finished", "status" to status, "openMs" to opened, "totalMs" to (System.nanoTime() - started) / 1_000_000,
                "events" to events.joinToString(","), "reply" to reply,
            )
        } catch (error: Exception) {
            OxLog.error("agent.probe.failed", "message" to error.message, "events" to events.joinToString(","))
        } finally {
            runCatching { runtime.command(buildJsonObject { put("action", "close") }) }
            runtime.close()
        }
    }

    private fun configuration() = buildJsonObject {
        put("model", MockModel.ID)
        putJsonObject("promptState") { put("memory", "") }
        put("isolatedFiles", true)
        put("providerID", MockModel.ID)
        put("thinkingLevel", JsonNull)
        put("nativeReasoningEffort", JsonNull)
        put("contextWindow", 200_000)
        put("maxTokens", 8_192)
        put("reasoning", false)
        put("systemUpdates", false)
        put("toolExecutionMode", "parallel")
        putJsonArray("tools") {}
        putJsonArray("messages") {}
    }

    private fun textOf(message: JsonElement): String =
        (message.jsonObject["content"] as? JsonArray).orEmpty()
            .mapNotNull { (it.jsonObject["text"] as? JsonPrimitive)?.contentOrNull }.joinToString("")
}
