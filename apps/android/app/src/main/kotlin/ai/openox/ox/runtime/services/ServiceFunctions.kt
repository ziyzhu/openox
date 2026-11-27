package ai.openox.ox.runtime.services

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.files.ProfileFiles
import ai.openox.ox.runtime.services.web.BrowserPages
import ai.openox.ox.runtime.vm.ExecutionBudget
import ai.openox.ox.runtime.vm.OxFunctionError
import android.content.SharedPreferences
import androidx.core.content.edit
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

fun interface Approver {
    suspend fun allows(conversation: Int, prompt: String): Boolean
}

class ServiceTools(
    private val pages: BrowserPages,
    private val services: Services,
    private val preferences: SharedPreferences,
    private val runtime: () -> String,
    private val approver: Approver,
) {
    private val trusted = ConcurrentHashMap<Int, MutableSet<String>>()

    fun attached(conversation: Int): Set<String> = preferences.getStringSet(key(conversation), emptySet()).orEmpty()

    suspend fun attachedServices(conversation: Int): List<ServiceDefinition> {
        val domains = attached(conversation)
        return if (domains.isEmpty()) emptyList() else services.entries().mapNotNull { it.definition }.filter { it.domain in domains }
    }

    suspend fun catalog(): List<ServiceDefinition> = services.entries().mapNotNull { it.definition }

    suspend fun assign(conversation: Int, domains: List<String>): Set<String> {
        val known = catalog().map { it.domain }.toSet()
        val chosen = domains.filter { it in known }.toSet()
        preferences.edit { putStringSet(key(conversation), chosen) }
        OxLog.info("services.assigned", "conversation" to conversation, "count" to chosen.size)
        return chosen
    }

    suspend fun forget(conversation: Int) {
        trusted.remove(conversation)
        preferences.edit { remove(key(conversation)) }
        pages.release(conversation)
    }

    suspend fun call(conversation: Int, name: String, arguments: JsonObject, budget: ExecutionBudget): JsonElement? = when (name) {
        "ox.web.browser.newPage" -> pages.open(conversation, arguments.required("url"))
        "ox.web.browser.goto" -> pages.navigate(conversation, arguments.required("pageId"), arguments.required("url"))
        "ox.web.browser.reload" -> pages.reload(conversation, arguments.required("pageId"))
        "ox.web.browser.goBack" -> pages.travel(conversation, arguments.required("pageId"), forward = false)
        "ox.web.browser.goForward" -> pages.travel(conversation, arguments.required("pageId"), forward = true)
        "ox.web.browser.waitForURL" -> pages.awaitUrl(
            conversation, arguments.required("pageId"), arguments.string("url"),
            ((arguments["timeoutMs"] as? JsonPrimitive)?.longOrNull ?: DEFAULT_WAIT_MS).coerceIn(100, MAX_WAIT_MS),
        )
        "ox.web.browser.frames" -> buildJsonObject {
            val attached = attached(conversation)
            val known = services.entries().mapNotNull { it.definition }
            putJsonArray("frames") { pages.frames(conversation, arguments.required("pageId")).forEach { add(described(it, known, attached)) } }
            put("framesTruncated", false)
        }
        "ox.web.browser.evaluate" -> {
            val frame = pages.frame(conversation, arguments.required("frameId"))
            authorize(conversation, frame.host, budget)
            pages.evaluate(conversation, frame.id, arguments.required("script"))
        }
        "ox.web.browser.snapshot" -> {
            val frame = pages.frame(conversation, arguments.required("frameId"))
            authorize(conversation, frame.host, budget)
            val attached = attached(conversation)
            val known = services.entries().mapNotNull { it.definition }
            JsonObject(pages.snapshot(conversation, frame.id, arguments.string("selector")) + mapOf(
                "frames" to buildJsonArray { add(described(frame, known, attached)) },
                "framesTruncated" to JsonPrimitive(false),
            ))
        }
        "ox.web.browser.showPage" -> buildJsonObject {
            put("status", if (budget.exempt { pages.present(conversation, arguments.required("pageId")) }) "completed" else "cancelled")
        }
        "ox.web.browser.close" -> buildJsonObject { put("closed", pages.close(conversation, arguments.required("pageId"))) }
        "ox.web.browser.pages" -> buildJsonObject {
            put("pages", pages.list(conversation))
            put("limit", PAGE_LIMIT)
        }
        "ox.service.list" -> {
            val attached = attached(conversation)
            val kind = arguments.string("kind")
            buildJsonArray {
                if (kind == null || kind == "web") services.entries().forEach { entry ->
                    add(entry.definition?.summary(entry.domain in attached) ?: buildJsonObject {
                        put("domain", entry.domain)
                        put("name", entry.domain)
                        put("kind", "web")
                        put("login", "unknown")
                        put("attached", false)
                        put("repository", entry.repository)
                        put("manifestPath", entry.manifestPath)
                        put("validationError", entry.error)
                    })
                }
            }
        }
        "ox.service.inspect" -> inspect(conversation, arguments)
        "ox.service.validate" -> services.validate(arguments.required("domain"))
        "ox.service.attach" -> {
            val service = services.resolve(arguments.required("domain"))
            attach(conversation, service.domain)
            service.summary(attached = true)
        }
        "ox.service.detach" -> {
            val service = services.resolve(arguments.required("domain"))
            preferences.edit { putStringSet(key(conversation), attached(conversation) - service.domain) }
            buildJsonObject {
                put("domain", service.domain)
                put("detached", true)
            }
        }
        "ox.service.listAttached" -> buildJsonArray { attachedServices(conversation).forEach { add(it.summary(attached = true)) } }
        "ox.service.invoke" -> budget.exempt { invoke(conversation, arguments) }
        "ox.repository.list" -> buildJsonObject {
            val entries = services.entries()
            put("status", "ready")
            putJsonArray("repositories") {
                listOf(Triple(ProfileFiles.BUILTIN, "Built-in", "bundled"), Triple(ProfileFiles.LOCAL, "Local", "local")).forEach { (id, title, provenance) ->
                    addJsonObject {
                        put("id", id)
                        put("path", "${ProfileFiles.REPOSITORIES}/$id")
                        put("name", title)
                        put("provenance", provenance)
                        put("enabled", true)
                        put("state", "ready")
                        put("serviceCount", entries.count { it.repository == id })
                        put("skillCount", 0)
                    }
                }
            }
            put("truncated", false)
        }
        else -> null
    }

    private suspend fun inspect(conversation: Int, arguments: JsonObject): JsonObject {
        val service = services.resolve(arguments.required("domain"))
        val custom = service.actions.filter { it.string("id") !in service.standard }.sortedBy { it.string("id").orEmpty() }
        val cursor = arguments.string("cursor")
        val start = if (cursor == null) 0 else custom.indexOfFirst { service.qualified(it.string("id").orEmpty()) == cursor }.also {
            if (it < 0) throw OxFunctionError("invalid_argument", "Invalid or stale service inspection cursor. Inspect the same service without cursor to restart pagination")
        } + 1
        val page = custom.drop(start).take(INSPECT_PAGE)
        return buildJsonObject {
            put("service", service.summary(service.domain in attached(conversation)))
            putJsonArray("standardActions") { service.standard.forEach { add(it) } }
            putJsonObject("actions") { page.forEach { action -> put(action.string("id").orEmpty(), service.contract(action)) } }
            putJsonArray("secrets") {}
            (service.manifest["auth"] as? JsonArray)?.let { put("auth", it) }
            if (start + page.size < custom.size) page.lastOrNull()?.let { put("nextCursor", service.qualified(it.string("id").orEmpty())) }
        }
    }

    private suspend fun invoke(conversation: Int, arguments: JsonObject): JsonElement {
        val name = arguments.required("name")
        val parts = name.split(':')
        if (parts.size != 3 || parts[0] != "web") {
            throw OxFunctionError("unavailable", "Only web service actions named web:<domain>:<action> are available on this device yet")
        }
        val service = services.resolve(parts[1])
        val action = service.action(parts[2])
            ?: throw OxFunctionError("unknown_action", "$name is not defined. Actions: ${service.actions.mapNotNull { it.string("id") }.joinToString(", ")}")
        val frameId = arguments.string("frameId")
            ?: throw OxFunctionError("frame_required", "Web service actions require an explicit frameId. Open a page or list its frames and select the matching document")
        val frame = pages.frame(conversation, frameId)
        if (!service.owns(frame.host)) {
            throw OxFunctionError("off_domain", "The frame is on ${frame.host}, outside ${service.domain}. Navigate the page to the action's baseUrl and use its fresh frameId")
        }
        val input = arguments["input"] as? JsonObject ?: JsonObject(emptyMap())
        val session = arguments["session"] as? JsonObject
        attach(conversation, service.domain)
        if (service.repository == ProfileFiles.LOCAL) authorize(conversation, frame.host, null)
        if (action.flag("requireApproval")) {
            val label = action.string("label") ?: parts[2]
            val preview = input.toString().take(APPROVAL_PREVIEW)
            if (!approver.allows(conversation, "Allow ${service.name} to run “$label”?\n$preview")) {
                throw OxFunctionError("permission_denied", "The user did not allow $name. No action was executed. Stop and do not retry unless the user asks")
            }
        }
        val standard = parts[2] == ServiceDefinition.LIST_SESSIONS || parts[2] == ServiceDefinition.LOGIN
        if (!standard && (action.flag("requireAuth") || session != null)) {
            if (!service.sessions) throw OxFunctionError("authentication_required", "$name requires authentication, but the service defines no listSessions and login actions")
            val known = run(conversation, service, frame, ServiceDefinition.LIST_SESSIONS, JsonObject(emptyMap())) as? JsonArray
            if (known.isNullOrEmpty() || (session != null && session !in known)) {
                throw OxFunctionError(
                    "authentication_required",
                    "No logged-in session was selected or discovered. No action was executed. Invoke the website's standard login action if needed, show the page with ox.web.browser.showPage, then list sessions again",
                )
            }
        }
        val started = System.nanoTime()
        try {
            return run(conversation, service, frame, parts[2], input)
        } finally {
            OxLog.info(
                "service.invoke", "service" to service.domain, "action" to parts[2], "repository" to service.repository,
                "durationMs" to (System.nanoTime() - started) / 1_000_000,
            )
        }
    }

    private suspend fun run(conversation: Int, service: ServiceDefinition, frame: BrowserPages.Frame, action: String, input: JsonObject): JsonElement {
        val key = JsonPrimitive("${service.domain}:${service.revision}")
        val script = """
            if (!Object.hasOwn(window, '__oxServiceRuntimes')) Object.defineProperty(window, '__oxServiceRuntimes', { value: new Map() });
            let __oxService = window.__oxServiceRuntimes.get($key);
            if (!__oxService) {
            ${runtime()}
              __oxService = window.__openOxCreateServiceRuntime(${JsonPrimitive(service.domain)});
              const __oxPrevious = window.ox;
              window.ox = __oxService;
              try {
                {
            ${service.source}
                }
              } finally {
                window.ox = __oxPrevious;
              }
              window.__oxServiceRuntimes.set($key, __oxService);
            }
            return await __oxService.callServiceAction(${JsonPrimitive(action)}, $input);
        """.trimIndent()
        return pages.evaluate(conversation, frame.id, script, ACTION_MS)
    }

    private suspend fun authorize(conversation: Int, host: String, budget: ExecutionBudget?) {
        val sites = trusted.getOrPut(conversation) { ConcurrentHashMap.newKeySet() }
        if (host in sites) return
        val prompt = "Allow Ox to inspect and run scripts on $host in this conversation?"
        val allowed = if (budget != null) budget.exempt { approver.allows(conversation, prompt) } else approver.allows(conversation, prompt)
        if (!allowed) throw OxFunctionError("permission_denied", "The user did not allow access to $host. Stop and do not retry unless the user asks")
        sites += host
    }

    private fun attach(conversation: Int, domain: String) {
        val current = attached(conversation)
        if (domain !in current) preferences.edit { putStringSet(key(conversation), current + domain) }
    }

    private fun described(frame: BrowserPages.Frame, known: List<ServiceDefinition>, attached: Set<String>) = buildJsonObject {
        val owner = known.filter { it.owns(frame.host) }.maxByOrNull { it.domain.length }
        put("id", frame.id)
        put("parentId", null as String?)
        put("origin", frame.origin)
        put("isMainFrame", true)
        put("serviceID", owner?.let { "web:${it.domain}" })
        put("attached", owner != null && owner.domain in attached)
    }

    private fun key(conversation: Int) = "services.$conversation"

    private fun JsonObject.required(key: String): String =
        string(key)?.takeIf { it.isNotBlank() } ?: throw OxFunctionError("invalid_argument", "Provide $key")

    private companion object {
        const val PAGE_LIMIT = 8
        const val INSPECT_PAGE = 10
        const val APPROVAL_PREVIEW = 400
        const val DEFAULT_WAIT_MS = 15_000L
        const val MAX_WAIT_MS = 120_000L
        const val ACTION_MS = 120_000L
    }
}
