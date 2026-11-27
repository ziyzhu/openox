package ai.openox.ox.runtime.services

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.files.ProfileFiles
import ai.openox.ox.runtime.vm.JavaScript
import ai.openox.ox.runtime.vm.OxFunctionError
import com.dokar.quickjs.binding.function
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

class Services(private val builtin: File, private val local: File, private val validator: () -> String) {
    private val verdicts = ConcurrentHashMap<String, List<String>>()

    suspend fun entries(): List<ServiceEntry> = withContext(Dispatchers.IO) {
        val drafts = registered(local).map { domain -> entry(local, ProfileFiles.LOCAL, domain, validate = true) }
        val shadowed = drafts.filter { it.definition != null }.map { it.domain }.toSet()
        val bundled = registered(builtin).filter { it !in shadowed }.map { domain -> entry(builtin, ProfileFiles.BUILTIN, domain, validate = false) }
        (drafts + bundled).sortedBy { it.domain }
    }

    suspend fun resolve(reference: String): ServiceDefinition {
        val wanted = reference.trim().removePrefix("web:").let { text -> text.toHttpUrlOrNull()?.host ?: text.substringBefore('/').lowercase() }
        val entries = entries()
        val exact = entries.filter { it.domain == wanted }
        val candidates = exact.ifEmpty { entries.filter { wanted.endsWith(".${it.domain}") || wanted == "www.${it.domain}" || it.domain == "www.$wanted" } }
        val chosen = candidates.firstOrNull { it.definition != null } ?: candidates.firstOrNull()
            ?: throw OxFunctionError("service_not_found", "No service is defined for $wanted. Missing coverage means build it: read skills/evolve/SKILL.md")
        return chosen.definition ?: throw OxFunctionError("invalid_service", "${chosen.manifestPath} is invalid: ${chosen.error}")
    }

    suspend fun validate(domain: String): JsonObject = withContext(Dispatchers.IO) {
        val clean = domain.trim().removePrefix("web:").lowercase()
        val directory = File(File(local, "web"), clean)
        if (!SAFE_DOMAIN.matches(clean) || !File(directory, MANIFEST).isFile) throw OxFunctionError("service_not_found", "No Local draft exists at repositories/local/web/$clean/service.json")
        val entry = entry(local, ProfileFiles.LOCAL, clean, validate = true)
        entry.error?.let { throw OxFunctionError("invalid_service", it) }
        if (clean !in registered(local)) throw OxFunctionError("invalid_service", "Register \"web:$clean\" in repositories/local/repository.json so the service can be selected")
        buildJsonObject {
            put("domain", clean)
            put("valid", true)
        }
    }

    private fun registered(root: File): List<String> {
        val listed = runCatching { Json.parseToJsonElement(File(root, "repository.json").readText()) }.getOrNull() as? JsonObject
        return (listed?.get("services") as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            .filter { it.startsWith("web:") }.map { it.removePrefix("web:") }.filter { SAFE_DOMAIN.matches(it) }.distinct()
    }

    private suspend fun entry(root: File, repository: String, domain: String, validate: Boolean): ServiceEntry {
        val directory = File(File(root, "web"), domain)
        val path = "${ProfileFiles.REPOSITORIES}/$repository/web/$domain/$MANIFEST"
        val manifest = runCatching { Json.parseToJsonElement(File(directory, MANIFEST).readText()) }.getOrNull() as? JsonObject
            ?: return ServiceEntry(domain, repository, null, path, "service.json is missing or is not a JSON object")
        val source = runCatching { File(directory, ACTIONS).readText() }.getOrNull() ?: return ServiceEntry(domain, repository, null, path, "actions.js is missing")
        if (source.length > MAX_SOURCE_CHARS) return ServiceEntry(domain, repository, null, path, "actions.js exceeds $MAX_SOURCE_CHARS characters")
        val definition = ServiceDefinition(domain, manifest, source, repository)
        val problems = if (validate) verdicts.getOrPut("${manifest.hashCode()}:${definition.revision}") { check(manifest, source) } else emptyList()
        val mismatch = manifest.string("domain")?.takeIf { it != domain }?.let { "manifest domain $it does not match its directory $domain" }
        val error = (listOfNotNull(mismatch) + problems).joinToString("; ").ifEmpty { null }
        return ServiceEntry(domain, repository, definition.takeIf { error == null }, path, error)
    }

    private suspend fun check(manifest: JsonObject, source: String): List<String> = try {
        JavaScript.run("ox-validate-js", 20.seconds, MEMORY_BYTES) { engine ->
            engine.function("__oxManifest") { manifest.toString() }
            engine.function("__oxSource") { source }
            engine.evaluate<Any?>(validator(), "ox-trusted://service-validation.js")
            Json.parseToJsonElement(engine.evaluate<String>(CHECK, "ox-trusted://validate.js")).jsonArray.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }
    } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
    } catch (error: Exception) {
        OxLog.warning("services.validation.failed", "message" to error.message?.lineSequence()?.firstOrNull())
        listOf("validation could not run: ${error.message?.lineSequence()?.firstOrNull()}")
    }

    private companion object {
        const val MANIFEST = "service.json"
        const val ACTIONS = "actions.js"
        const val MAX_SOURCE_CHARS = 1_000_000
        const val MEMORY_BYTES = 128L * 1024 * 1024
        val SAFE_DOMAIN = Regex("""[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+""")

        val CHECK = """
            (() => {
              const manifest = JSON.parse(__oxManifest());
              const problems = [];
              const collect = run => {
                try { problems.push(...run()); } catch (error) { problems.push(String(error && error.message || error)); }
              };
              collect(() => OxServiceValidation.validateManifest(manifest));
              if (!problems.length) collect(() => OxServiceValidation.inspectInstaller(__oxSource(), manifest));
              return JSON.stringify(problems);
            })()
        """.trimIndent()
    }
}
