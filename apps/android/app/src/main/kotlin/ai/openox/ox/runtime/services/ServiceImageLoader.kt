package ai.openox.ox.runtime.services

import ai.openox.ox.diagnostics.OxLog
import android.util.Base64
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

class ServiceIcons(private val directory: File, private val http: OkHttpClient) {
    private val downloads = Semaphore(PARALLEL)

    fun cached(address: String?): String? {
        val file = address?.let(::file)?.takeIf { it.isFile && it.length() > 0 } ?: return null
        return "data:image/png;base64," + Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }

    suspend fun warm(addresses: Collection<String>) {
        val missing = addresses.distinct().filter { !file(it).isFile }
        if (missing.isEmpty()) return
        val started = System.nanoTime()
        withTimeoutOrNull(WARM_MS) {
            coroutineScope { missing.map { address -> async { downloads.withPermit { fetch(address) } } }.awaitAll() }
        }
        OxLog.info("services.icons.warmed", "requested" to missing.size, "durationMs" to (System.nanoTime() - started) / 1_000_000)
    }

    private suspend fun fetch(address: String) = withContext(Dispatchers.IO) {
        val url = address.toHttpUrlOrNull()?.takeIf { it.isHttps } ?: return@withContext
        runCatching {
            http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                val bytes = response.body.source().apply { request(MAX_BYTES + 1L) }.buffer.takeIf { response.isSuccessful && it.size in 1..MAX_BYTES }?.readByteArray()
                directory.mkdirs()
                file(address).writeBytes(bytes ?: ByteArray(0))
            }
        }
    }

    private fun file(address: String) =
        File(directory, MessageDigest.getInstance("SHA-256").digest(address.toByteArray()).joinToString("") { "%02x".format(it) })

    private companion object {
        const val PARALLEL = 8
        const val MAX_BYTES = 256 * 1024
        const val WARM_MS = 2_500L
    }
}
