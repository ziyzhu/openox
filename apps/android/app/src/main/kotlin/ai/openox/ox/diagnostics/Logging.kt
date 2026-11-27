package ai.openox.ox.diagnostics

import android.util.Log
import java.io.File
import java.time.Instant
import java.util.concurrent.Executors

object OxLog {
    private const val TAG = "Ox"
    private const val MAX_BYTES = 512 * 1024L
    private val writer = Executors.newSingleThreadExecutor { task -> Thread(task, "ox-log").apply { isDaemon = true } }
    private val whitespace = Regex("\\s+")

    @Volatile
    private var directory: File? = null

    fun attach(filesDirectory: File) {
        directory = File(filesDirectory, "logs").apply { mkdirs() }
    }

    fun info(event: String, vararg fields: Pair<String, Any?>) {
        val line = line(event, fields)
        Log.i(TAG, line)
        persist("info", line)
    }

    fun warning(event: String, vararg fields: Pair<String, Any?>) {
        val line = line(event, fields)
        Log.w(TAG, line)
        persist("warning", line)
    }

    fun error(event: String, vararg fields: Pair<String, Any?>) {
        val line = line(event, fields)
        Log.e(TAG, line)
        persist("error", line)
    }

    fun export(): File? {
        val target = directory ?: return null
        return writer.submit<File?> {
            val files = listOf(File(target, PREVIOUS), File(target, CURRENT)).filter { it.exists() }
            if (files.isEmpty()) return@submit null
            File(target, EXPORT).apply {
                outputStream().use { output -> files.forEach { file -> file.inputStream().use { it.copyTo(output) } } }
            }
        }.get()
    }

    private fun persist(level: String, line: String) {
        val target = directory ?: return
        val time = Instant.now()
        writer.execute {
            runCatching {
                val current = File(target, CURRENT)
                if (current.length() > MAX_BYTES) {
                    val previous = File(target, PREVIOUS)
                    previous.delete()
                    current.renameTo(previous)
                }
                current.appendText("$time $level $line\n")
            }.onFailure { Log.w(TAG, "log.persist.failed message=${it.message}") }
        }
    }

    private fun line(event: String, fields: Array<out Pair<String, Any?>>): String =
        buildString {
            append(event)
            for ((key, value) in fields) {
                append(' ').append(key).append('=').append(value.toString().replace(whitespace, " "))
            }
        }

    private const val CURRENT = "ox.log"
    private const val PREVIOUS = "ox.1.log"
    private const val EXPORT = "ox-logs.txt"
}
