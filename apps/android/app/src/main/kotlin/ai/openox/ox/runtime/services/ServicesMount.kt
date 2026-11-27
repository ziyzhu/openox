package ai.openox.ox.runtime.services

import ai.openox.ox.BuildConfig
import ai.openox.ox.diagnostics.OxLog
import android.content.Context
import java.io.File

object ServiceBundle {
    fun install(context: Context): File {
        val updated = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        val root = File(context.filesDir, "bundles")
        val target = File(root, "${BuildConfig.VERSION_CODE}-$updated")
        val complete = File(root, "${target.name}.complete")
        if (complete.isFile) return target
        val started = System.nanoTime()
        root.deleteRecursively()
        val paths = context.assets.open("$ASSETS/index.txt").bufferedReader().use { it.readLines() }.filter { it.isNotBlank() }
        paths.forEach { path ->
            val file = File(target, path)
            file.parentFile?.mkdirs()
            context.assets.open("$ASSETS/$path").use { input -> file.outputStream().use { input.copyTo(it) } }
        }
        complete.writeText(paths.size.toString())
        OxLog.info("services.bundle.installed", "files" to paths.size, "durationMs" to (System.nanoTime() - started) / 1_000_000)
        return target
    }

    fun skills(bundle: File): List<Pair<String, String>> = SKILLS.mapNotNull { name ->
        val lines = runCatching { File(bundle, "skills/$name/SKILL.md").readLines() }.getOrNull() ?: return@mapNotNull null
        val description = lines.firstOrNull { it.startsWith("description:") }?.removePrefix("description:")?.trim()?.removeSurrounding("\"") ?: return@mapNotNull null
        name to description
    }

    private const val ASSETS = "services"
    private val SKILLS = listOf("evolve", "authentication", "checkout")
}
