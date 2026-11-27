package ai.openox.ox.runtime.services

import ai.openox.ox.runtime.files.ProfileFiles
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

class ServiceDefinition(val domain: String, val manifest: JsonObject, val source: String, val repository: String) {
    val name: String get() = manifest.string("name") ?: domain
    val description: String? get() = manifest.string("description")
    val revision: String = MessageDigest.getInstance("SHA-256").digest(source.toByteArray()).take(8).joinToString("") { "%02x".format(it) }
    val actions: List<JsonObject> = (manifest["actions"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
    val sessions: Boolean = action(LIST_SESSIONS) != null && action(LOGIN) != null
    val standard: List<String> = STANDARD.filter { id -> action(id) != null && (id == SEARCH || sessions) }

    fun action(id: String): JsonObject? = actions.firstOrNull { it.string("id") == id }

    fun owns(host: String): Boolean = host == domain || host.endsWith(".$domain")

    fun qualified(action: String) = "web:$domain:$action"

    fun summary(attached: Boolean) = buildJsonObject {
        put("domain", domain)
        put("name", name)
        description?.let { put("description", it) }
        put("kind", "web")
        put("login", if (sessions) "unknown" else "notRequired")
        put("attached", attached)
        put("repository", repository)
        put("repositoryProvenance", if (repository == ProfileFiles.LOCAL) "local" else "bundled")
        put("faviconUrl", manifest.string("faviconUrl"))
    }

    fun contract(action: JsonObject) = buildJsonObject {
        (action.string("description") ?: action.string("label"))?.let { put("description", it) }
        put("requireAuth", action.flag("requireAuth"))
        if (action.flag("requireApproval")) put("requireApproval", true)
        (action.string("baseUrl") ?: manifest.string("baseUrl"))?.let { put("baseUrl", it) }
        put("inputSchema", scoped(action["inputSchema"] as? JsonObject ?: JsonObject(emptyMap())))
        (action["outputSchema"] as? JsonObject)?.let { put("outputSchema", scoped(it)) }
    }

    private fun scoped(schema: JsonObject): JsonObject = manifest["\$defs"]?.let { JsonObject(schema + ("\$defs" to it)) } ?: schema

    companion object {
        const val LIST_SESSIONS = "listSessions"
        const val LOGIN = "login"
        const val SEARCH = "search"
        val STANDARD = listOf(LIST_SESSIONS, LOGIN, SEARCH)
    }
}

class ServiceEntry(val domain: String, val repository: String, val definition: ServiceDefinition?, val manifestPath: String, val error: String?)

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

internal fun JsonObject.flag(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull == true
