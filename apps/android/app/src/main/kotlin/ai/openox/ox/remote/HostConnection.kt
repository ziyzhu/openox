package ai.openox.ox.remote

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.platform.models.HostEndpoint
import java.util.UUID
import kotlin.time.Duration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

interface HostLink {
    val generation: Int

    suspend fun request(method: String, params: JsonObject, timeout: Duration): JsonElement

    fun close()
}

class HostConnection(
    private val endpoint: HostEndpoint.Remote,
    private val http: OkHttpClient,
    private val json: Json,
) : HostLink {
    private sealed interface Link {
        data object Closed : Link
        class Connecting(val socket: WebSocket) : Link
        class Open(val socket: WebSocket) : Link
    }

    private class Pending(val method: String, val frame: String, val reply: CompletableDeferred<JsonElement>) {
        var sent = false
    }

    private val lock = Any()
    private var link: Link = Link.Closed
    private var generationCount = 0
    private val pending = LinkedHashMap<String, Pending>()

    override val generation: Int get() = synchronized(lock) { generationCount }

    override suspend fun request(method: String, params: JsonObject, timeout: Duration): JsonElement {
        val id = UUID.randomUUID().toString()
        val frame = buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", id)
            put("method", method)
            put("params", params)
        }.toString()
        val entry = Pending(method, frame, CompletableDeferred())
        synchronized(lock) {
            pending[id] = entry
            when (val current = link) {
                is Link.Open -> entry.sent = current.socket.send(frame)
                is Link.Connecting -> Unit
                Link.Closed -> connect()
            }
        }
        try {
            return withTimeout(timeout) { entry.reply.await() }
        } catch (_: TimeoutCancellationException) {
            OxLog.warning("host.request.timeout", "method" to method, "sent" to entry.sent, "timeoutMs" to timeout.inWholeMilliseconds)
            throw HostError.Unavailable("Timed out after ${timeout.inWholeSeconds} s", entry.sent)
        } finally {
            synchronized(lock) { pending.remove(id) }
        }
    }

    override fun close() {
        val socket = synchronized(lock) { currentSocket() }
        if (socket != null) disconnect(socket, "Connection closed")
    }

    private fun connect() {
        generationCount += 1
        OxLog.info("host.connect", "endpoint" to endpoint, "generation" to generationCount)
        val request = Request.Builder().url(endpoint.url).build()
        link = Link.Connecting(http.newWebSocket(request, Listener()))
    }

    private fun currentSocket(): WebSocket? = when (val current = link) {
        is Link.Open -> current.socket
        is Link.Connecting -> current.socket
        Link.Closed -> null
    }

    private fun receive(socket: WebSocket, text: String) {
        val message = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
        if (message == null || message["jsonrpc"]?.jsonPrimitive?.contentOrNull != "2.0") {
            disconnect(socket, "Host returned an invalid JSON-RPC message")
            return
        }
        val id = (message["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (id == null) {
            if (message["method"] != null) return
            disconnect(socket, "Host returned a response without a request ID")
            return
        }
        val entry = synchronized(lock) { pending.remove(id) } ?: return
        val result = message["result"]
        val error = message["error"] as? JsonObject
        when {
            result != null -> entry.reply.complete(result)
            error != null -> {
                val code = error["code"]?.jsonPrimitive?.intOrNull ?: 0
                val text = error["message"]?.jsonPrimitive?.contentOrNull ?: "Host error"
                OxLog.warning("host.request.error", "method" to entry.method, "code" to code, "message" to text)
                entry.reply.completeExceptionally(HostError.Rpc(code, text))
            }
            else -> entry.reply.completeExceptionally(HostError.Invalid("Host returned a response without a result"))
        }
    }

    private fun disconnect(socket: WebSocket, reason: String) {
        val failed = synchronized(lock) {
            if (currentSocket() !== socket) return
            link = Link.Closed
            val values = pending.values.toList()
            pending.clear()
            values
        }
        OxLog.info("host.disconnect", "endpoint" to endpoint, "reason" to reason, "failedRequests" to failed.size)
        failed.forEach { it.reply.completeExceptionally(HostError.Unavailable(reason, it.sent)) }
        socket.cancel()
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(lock) {
                val current = link
                if (current !is Link.Connecting || current.socket !== webSocket) return
                link = Link.Open(webSocket)
                pending.values.filterNot { it.sent }.forEach { it.sent = webSocket.send(it.frame) }
            }
            OxLog.info("host.open", "endpoint" to endpoint)
        }

        override fun onMessage(webSocket: WebSocket, text: String) = receive(webSocket, text)

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) =
            disconnect(webSocket, "Host closed the connection ($code)")

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
            disconnect(webSocket, "Host connection failed: ${t.message ?: t.javaClass.simpleName}")
    }
}
