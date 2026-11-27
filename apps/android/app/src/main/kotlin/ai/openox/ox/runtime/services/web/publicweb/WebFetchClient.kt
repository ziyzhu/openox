package ai.openox.ox.runtime.services.web.publicweb

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.vm.JavaScript
import ai.openox.ox.runtime.vm.OxFunctionError
import com.dokar.quickjs.binding.function
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer

object PublicAddress {
    fun allows(address: InetAddress): Boolean {
        val bytes = address.address
        val uniqueLocal = bytes.size == 16 && (bytes[0].toInt() and 0xFE) == 0xFC
        val sharedRange = bytes.size == 4 && bytes[0].toInt() == 100 && (bytes[1].toInt() and 0xC0) == 64
        return !(address.isLoopbackAddress || address.isSiteLocalAddress || address.isLinkLocalAddress || address.isAnyLocalAddress || address.isMulticastAddress || uniqueLocal || sharedRange)
    }

    suspend fun require(host: String) = withContext(Dispatchers.IO) {
        if (InetAddress.getAllByName(host).any { !allows(it) }) throw UnknownHostException("$host is not a public address")
    }
}

class WebFetch(http: OkHttpClient, private val extractionBundle: () -> String) {
    private val client = http.newBuilder()
        .dns { host -> Dns.SYSTEM.lookup(host).onEach { if (!PublicAddress.allows(it)) throw UnknownHostException("$host is not a public address") } }
        .cookieJar(CookieJar.NO_COOKIES)
        .followRedirects(false)
        .followSslRedirects(false)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    suspend fun fetch(arguments: JsonObject): JsonElement {
        val address = (arguments["url"] as? JsonPrimitive)?.contentOrNull?.toHttpUrlOrNull()
            ?: throw OxFunctionError("invalid_arguments", "Provide an absolute public HTTP or HTTPS URL")
        val limit = ((arguments["options"] as? JsonObject)?.get("maxBytes") as? JsonPrimitive)?.intOrNull?.coerceIn(1, MAX_BODY_BYTES) ?: DEFAULT_TEXT_BYTES
        val started = System.nanoTime()
        var hops = 0
        var response = request(address)
        while (response.isRedirect) {
            val next = response.header("Location")?.let { response.request.url.resolve(it) }
            response.close()
            hops += 1
            if (next == null || hops > MAX_REDIRECTS) throw OxFunctionError("fetch_failed", "Could not fetch ${address.host}: too many redirects")
            response = request(next)
        }
        val redirected = hops > 0
        return withContext(Dispatchers.IO) {
            response.use {
                val type = response.header("Content-Type").orEmpty().substringBefore(';').trim().lowercase()
                val kind = kind(type)
                val body = Buffer()
                val complete = try {
                    if (kind in READABLE) {
                        val source = response.body.source()
                        var more = true
                        while (more && body.size <= MAX_BODY_BYTES) more = source.read(body, 64 * 1024) != -1L
                        body.size <= MAX_BODY_BYTES
                    } else true
                } catch (error: IOException) {
                    throw OxFunctionError("fetch_failed", "Could not read ${address.host}: ${error.message ?: error.javaClass.simpleName}")
                }
                val bytes = if (kind in READABLE) body.size else response.body.contentLength().coerceAtLeast(0)
                val raw = if (kind in READABLE) body.readUtf8(minOf(body.size, MAX_BODY_BYTES.toLong())) else null
                val readable = when {
                    raw == null -> null
                    kind == "html" && complete -> markdown(raw, response.request.url.toString()) ?: raw
                    else -> raw
                }
                val text = readable?.let { clipped(it, limit) }
                OxLog.info(
                    "web.fetch", "host" to address.host, "status" to response.code, "kind" to kind, "bytes" to bytes,
                    "durationMs" to (System.nanoTime() - started) / 1_000_000,
                )
                buildJsonObject {
                    put("ok", response.isSuccessful)
                    put("status", response.code)
                    put("statusText", response.message)
                    put("url", response.request.url.toString())
                    put("redirected", redirected)
                    putJsonObject("headers") {
                        response.headers.names().filterNot { it.lowercase() in PRIVATE_HEADERS }.forEach { name -> put(name.lowercase(), response.headers.values(name).joinToString(", ")) }
                    }
                    put("kind", kind)
                    put("filename", response.request.url.pathSegments.lastOrNull { it.isNotEmpty() } ?: response.request.url.host)
                    put("bytes", bytes)
                    put("text", text)
                    put("truncated", !complete || (readable != null && text != readable))
                    put("attached", false)
                    put("unsupported", when (kind) {
                        "pdf" -> "PDF text extraction is not available on this device yet."
                        "image", "file" -> "Only metadata is available for this file type on this device."
                        else -> null
                    })
                }
            }
        }
    }

    private suspend fun request(address: HttpUrl): Response {
        try {
            if (LITERAL.matches(address.host)) PublicAddress.require(address.host)
            val call = client.newCall(Request.Builder().url(address).header("Accept", ACCEPT).header("User-Agent", USER_AGENT).build())
            return suspendCancellableCoroutine { continuation ->
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) = continuation.resumeWithException(e)
                    override fun onResponse(call: Call, response: Response) = continuation.resume(response)
                })
            }
        } catch (error: IOException) {
            throw OxFunctionError("fetch_failed", "Could not fetch ${address.host}: ${error.message ?: error.javaClass.simpleName}")
        }
    }

    private suspend fun markdown(html: String, url: String): String? = try {
        JavaScript.run("ox-extract-js", 20.seconds, MEMORY_BYTES) { engine ->
            engine.function("__oxHtml") { html }
            engine.function("__oxUrl") { url }
            engine.evaluate<Any?>(PRELUDE, "ox-trusted://extract-prelude.js")
            engine.evaluate<Any?>(extractionBundle(), "ox-trusted://web-extraction.js")
            engine.evaluate<String?>(EXTRACT, "ox-trusted://extract.js")?.takeIf { it.isNotBlank() }
        }
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        OxLog.warning("web.extract.failed", "message" to error.message?.lineSequence()?.firstOrNull())
        null
    }

    private fun clipped(text: String, limit: Int): String {
        val bytes = text.toByteArray()
        if (bytes.size <= limit) return text
        var end = limit
        while (end > 0 && bytes[end].toInt() and 0xC0 == 0x80) end--
        return String(bytes, 0, end)
    }

    private fun kind(type: String): String = when {
        type == "text/html" || type == "application/xhtml+xml" -> "html"
        type == "application/pdf" -> "pdf"
        type.startsWith("image/") -> "image"
        type.startsWith("text/") || type in TEXT_TYPES || type.endsWith("+json") || type.endsWith("+xml") -> "text"
        else -> "file"
    }

    private companion object {
        const val MAX_BODY_BYTES = 8 * 1024 * 1024
        const val MAX_REDIRECTS = 5
        val PRIVATE_HEADERS = setOf("set-cookie", "set-cookie2")
        val LITERAL = Regex("""[0-9.]+|.*:.*""")
        const val DEFAULT_TEXT_BYTES = 256 * 1024
        const val MEMORY_BYTES = 256L * 1024 * 1024
        const val ACCEPT = "text/html,application/xhtml+xml,application/json,text/plain,*/*;q=0.8"
        const val USER_AGENT = "Mozilla/5.0 (Linux; Android) Ox"
        val READABLE = setOf("html", "text")
        val TEXT_TYPES = setOf("application/json", "application/xml", "application/javascript", "application/x-ndjson", "application/rss+xml", "application/atom+xml")

        val PRELUDE = """
            globalThis.setTimeout = globalThis.setInterval = () => { throw new Error('Timers unavailable during HTML extraction'); };
            globalThis.clearTimeout = globalThis.clearInterval = () => {};
            globalThis.atob = value => {
              const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
              let output = '', bits = 0, count = 0;
              for (const character of String(value).replace(/=+${'$'}/, '')) {
                const index = table.indexOf(character);
                if (index < 0) continue;
                bits = (bits << 6) | index;
                count += 6;
                if (count >= 8) {
                  count -= 8;
                  output += String.fromCharCode((bits >> count) & 255);
                }
              }
              return output;
            };
            globalThis.console = { log() {}, warn() {}, error() {}, debug() {}, info() {} };
            globalThis.Intl = { NumberFormat: function () { return { format: value => String(Number(Number(value).toFixed(6))) }; } };
        """.trimIndent()

        val EXTRACT = """
            await (async () => {
              const result = OxWebExtraction.extract(__oxHtml(), __oxUrl());
              for (let turn = 0; turn < 1000 && !result.settled; turn++) await null;
              return result.settled && !result.error ? result.content : null;
            })()
        """.trimIndent()
    }
}
