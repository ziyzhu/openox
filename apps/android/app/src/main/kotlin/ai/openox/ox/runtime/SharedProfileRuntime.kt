package ai.openox.ox.runtime

import ai.openox.ox.BuildConfig
import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.agent.llm.ModelRequest
import ai.openox.ox.runtime.agent.llm.ModelTransports
import ai.openox.ox.runtime.agent.llm.providers.MockModel
import ai.openox.ox.runtime.agent.llm.providers.chatgpt.ChatGptFailure
import ai.openox.ox.runtime.conversations.OxTools
import ai.openox.ox.runtime.durable.AgentDatabase
import ai.openox.ox.runtime.durable.AgentRuntime
import ai.openox.ox.runtime.durable.AgentRuntimeException
import ai.openox.ox.runtime.files.ProfileFiles
import ai.openox.ox.runtime.modelproviders.ModelDefinition
import ai.openox.ox.runtime.modelproviders.ModelProviders
import ai.openox.ox.runtime.modelproviders.ProviderDefinition
import ai.openox.ox.runtime.modelproviders.ProviderEntry
import ai.openox.ox.runtime.modelproviders.WireProtocol
import ai.openox.ox.runtime.services.ServiceBundle
import ai.openox.ox.runtime.services.ServiceIcons
import ai.openox.ox.runtime.services.ServiceTools
import ai.openox.ox.runtime.services.Services
import ai.openox.ox.runtime.services.string
import ai.openox.ox.runtime.services.web.BrowserPages
import ai.openox.ox.runtime.services.web.publicweb.WebFetch
import ai.openox.ox.runtime.vm.ToolCatalog
import ai.openox.ox.remote.HostError
import ai.openox.ox.remote.HostLink
import android.content.Context
import android.os.Build
import androidx.core.content.edit
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.time.Duration
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

class LocalHost(context: Context) : HostLink {
    private sealed interface Run {
        data object Idle : Run
        class Active(val job: Job) : Run
    }

    private sealed interface Ending {
        data object Stopped : Ending
        data class Failed(val message: String) : Ending
    }

    private class Queued(val id: String, val text: String)

    private class Prompt(val id: String, val text: String, val answer: CompletableDeferred<String>)

    private data class Choice(val providerId: String, val modelId: String, val effort: String? = null)

    private class Session(val number: Int) {
        var messages: List<JsonObject> = emptyList()
        var live: JsonObject? = null
        var streamed: JsonObject? = null
        var interrupted: JsonObject? = null
        var run: Run = Run.Idle
        var ending: Ending? = null
        var queue: List<Queued> = emptyList()
        var prompt: Prompt? = null
        var loaded = false
        var choice = MOCK
        val running: Boolean get() = run is Run.Active
    }

    private val application = context.applicationContext
    private val preferences = application.getSharedPreferences("agent", Context.MODE_PRIVATE)
    private val profileId = preferences.getString(PROFILE_KEY, null) ?: UUID.randomUUID().toString().uppercase().also { id ->
        preferences.edit { putString(PROFILE_KEY, id) }
    }
    private val serial = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + serial)
    private val sessions = mutableMapOf<Int, Session>()
    private val providers by lazy { ModelProviders.get(application) }
    private val transports by lazy { ModelTransports(providers.http) }
    private val runtime = AgentRuntime(
        bundle = { application.assets.open("agent/harness.js").bufferedReader().use { it.readText() } },
        database = AgentDatabase(File(application.filesDir, "profiles/$profileId/.ox/state.sqlite")),
    ) { method, params, stream -> withContext(serial) { native(method, params, stream) } }
    private val bundle by lazy { ServiceBundle.install(application) }
    private val files by lazy {
        ProfileFiles(
            File(application.filesDir, "profiles/$profileId/files"), File(application.cacheDir, "agent-tmp"),
            bundle, File(application.filesDir, "profiles/$profileId/repositories/local"),
        )
    }
    private val icons by lazy { ServiceIcons(File(application.cacheDir, "service-icons"), providers.http) }
    private val services by lazy {
        ServiceTools(
            pages = BrowserPages.get(application),
            services = Services(bundle, File(application.filesDir, "profiles/$profileId/repositories/local")) { asset("service-validation.js") },
            preferences = preferences,
            runtime = { asset("service-runtime.js") },
            approver = { conversation, prompt -> confirm(conversation, prompt) },
        )
    }
    private val catalog = scope.async(start = CoroutineStart.LAZY) { ToolCatalog.load(application.assets) }
    private val tools = scope.async(start = CoroutineStart.LAZY) {
        OxTools(
            catalog = catalog.await(),
            files = files,
            web = WebFetch(providers.http) { asset("web-extraction.js") },
            filesystem = { capability, operation, arguments ->
                runtime.command(buildJsonObject {
                    put("action", "filesystem")
                    put("profileID", profileId)
                    put("capability", capability)
                    put("operation", operation)
                    put("arguments", arguments)
                    put("fileMounts", files.mounts)
                })
            },
            rename = { conversation, title ->
                withContext(serial) { save(sessions.getOrPut(conversation) { Session(conversation) }) { put("title", title) } }
                true
            },
            services = services,
        )
    }
    private val profile = scope.async(start = CoroutineStart.LAZY) {
        runtime.command(buildJsonObject {
            put("action", "open")
            put("profileID", profileId)
        })
        OxLog.info("localHost.opened", "profile" to profileId)
    }

    override val generation = 1

    override suspend fun request(method: String, params: JsonObject, timeout: Duration): JsonElement = withContext(serial) {
        try {
            if (method != "profile.describe") profile.await()
            when (method) {
                "profile.describe" -> describe()
                "providers.list" -> providers()
                "conversations.list" -> list()
                "conversations.new" -> create(params)
                "conversations.view" -> view(session(params))
                "conversations.send" -> send(session(params), params)
                "conversations.stop" -> stop(session(params))
                "conversations.respond" -> respond(session(params), params)
                "conversations.setModel" -> setModel(session(params), params)
                "conversations.setServices" -> {
                    val domains = (params["domains"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                    services.assign(session(params).number, domains)
                    JsonObject(emptyMap())
                }
                "services.list" -> serviceRows()
                "conversations.rename" -> save(session(params)) { put("title", params.text("title") ?: throw HostError.Rpc(INVALID_PARAMS, "provide a title")) }
                "conversations.pin" -> save(session(params)) { put("favorite", (params["pinned"] as? JsonPrimitive)?.booleanOrNull == true) }
                "conversations.delete" -> delete(session(params))
                else -> throw HostError.Rpc(METHOD_NOT_FOUND, "$method is not available on this device yet")
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: HostError) {
            throw error
        } catch (error: Exception) {
            OxLog.warning("localHost.request.failed", "method" to method, "message" to error.message)
            throw HostError.Rpc(INTERNAL_ERROR, error.message?.lineSequence()?.firstOrNull() ?: "The on-device Host failed")
        }
    }

    override fun close() {
        scope.launch {
            sessions.values.forEach { (it.run as? Run.Active)?.job?.cancel() }
            if (profile.isCompleted && !profile.isCancelled) runCatching { runtime.command(buildJsonObject { put("action", "close") }) }
            runtime.close()
            OxLog.info("localHost.closed")
            scope.cancel()
        }
    }

    private fun describe() = buildJsonObject {
        putJsonObject("implementation") {
            put("name", "Ox for Android")
            put("version", BuildConfig.VERSION_NAME)
            put("build", BuildConfig.VERSION_CODE.toString())
        }
        putJsonObject("device") { put("name", Build.MODEL) }
        putJsonObject("protocols") { putJsonArray("rpc") { add(RPC_VERSION) } }
        putJsonArray("methods") { METHODS.forEach { add(it) } }
    }

    private suspend fun providers(): JsonElement {
        providers.discover()
        val ready = providers.entries.value.filter { it.ready && it.definition.models.isNotEmpty() }
        val default = defaultChoice(ready)
        return buildJsonObject {
            put("region", providers.region)
            putJsonArray("providers") {
                ready.forEach { entry ->
                    addJsonObject {
                        put("id", entry.definition.id)
                        put("displayName", entry.definition.name)
                        putJsonArray("models") {
                            entry.definition.models.forEach { model ->
                                addJsonObject {
                                    put("id", model.id)
                                    put("displayName", model.name)
                                    put("reasoning", model.reasoningEfforts.isNotEmpty())
                                    putJsonArray("reasoningEfforts") { efforts(entry.definition, model).forEach { add(it) } }
                                }
                            }
                        }
                    }
                }
                addJsonObject {
                    put("id", MockModel.ID)
                    put("displayName", MockModel.NAME)
                    putJsonArray("models") { add(model(MOCK)) }
                }
            }
            putJsonObject("defaultModel") {
                put("providerId", default.providerId)
                put("modelId", default.modelId)
            }
        }
    }

    private fun defaultChoice(ready: List<ProviderEntry>): Choice {
        val saved = providers.defaultModel?.let { Choice(it.first, it.second) }
        fun available(choice: Choice) = ready.any { entry -> entry.definition.id == choice.providerId && entry.definition.models.any { it.id == choice.modelId } }
        return saved?.takeIf(::available) ?: ready.firstOrNull()?.let { Choice(it.definition.id, it.definition.models.first().id) } ?: MOCK
    }

    private fun definition(choice: Choice): ModelDefinition? =
        providers.entry(choice.providerId)?.definition?.models?.firstOrNull { it.id == choice.modelId }

    private fun efforts(provider: ProviderDefinition, model: ModelDefinition): List<String> =
        if (provider.api == WireProtocol.Responses || (provider.api == WireProtocol.ChatCompletions && provider.options.reasoningFormat == "reasoning_effort")) model.reasoningEfforts else emptyList()

    private fun chosen(params: JsonObject): Choice? {
        val choice = params.text("providerId")?.let { provider -> params.text("modelId")?.let { Choice(provider, it) } } ?: return null
        if (choice == MOCK) return choice
        val provider = providers.entry(choice.providerId)?.takeIf { it.ready }?.definition
        val model = provider?.models?.firstOrNull { it.id == choice.modelId } ?: throw HostError.Rpc(INVALID_PARAMS, "unknown model: ${choice.providerId}/${choice.modelId}")
        return choice.copy(effort = params.text("reasoningEffort")?.takeIf { it in efforts(provider, model) })
    }

    private fun remember(session: Session) = preferences.edit {
        putString("model.${session.number}", buildJsonObject {
            put("providerId", session.choice.providerId)
            put("modelId", session.choice.modelId)
            session.choice.effort?.let { put("effort", it) }
        }.toString())
    }

    private suspend fun setModel(session: Session, params: JsonObject): JsonElement {
        load(session)
        if (session.running) throw HostError.Rpc(INVALID_PARAMS, "Wait for the reply to finish before changing the model")
        session.choice = chosen(params) ?: throw HostError.Rpc(INVALID_PARAMS, "provide a model")
        remember(session)
        OxLog.info("localHost.conversation.model", "conversation" to session.number, "provider" to session.choice.providerId, "model" to session.choice.modelId, "effort" to session.choice.effort)
        return JsonObject(emptyMap())
    }

    private fun model(choice: Choice) = buildJsonObject {
        choice.effort?.let { put("reasoningEffort", it) }
        put("id", choice.modelId)
        put("displayName", if (choice == MOCK) MockModel.NAME else definition(choice)?.name ?: choice.modelId)
    }

    private suspend fun list(): JsonElement {
        val rows = mutableListOf<JsonObject>()
        var cursor: JsonElement = JsonNull
        do {
            val page = runtime.command(buildJsonObject {
                put("action", "applicationList")
                put("limit", LIST_PAGE)
                put("listCursor", cursor)
            }) as JsonObject
            (page["items"] as? JsonArray).orEmpty().forEach { item -> row(item as JsonObject)?.let(rows::add) }
            cursor = page["next"] ?: JsonNull
        } while (cursor !is JsonNull)
        return buildJsonObject { put("conversations", JsonArray(rows)) }
    }

    private fun row(item: JsonObject): JsonObject? {
        val number = ((item["reference"] as? JsonObject)?.get("conversationID") as? JsonPrimitive)?.intOrNull ?: return null
        val at = (item["lastMessageAt"] as? JsonPrimitive)?.longOrNull?.let { Instant.ofEpochMilli(it).toString() } ?: return null
        val session = sessions[number]
        return buildJsonObject {
            put("id", identifier(number))
            put("title", (item["presentation"] as? JsonObject)?.text("title").orEmpty())
            put("model", ((item["agent"] as? JsonObject)?.get("model") as? JsonObject)?.text("modelId") ?: MockModel.ID)
            put("createdAt", at)
            put("lastActivity", at)
            put("active", false)
            put("pinned", (item["favorite"] as? JsonPrimitive)?.booleanOrNull == true)
            put("status", status(session, (item["unread"] as? JsonPrimitive)?.booleanOrNull == true))
        }
    }

    private fun status(session: Session?, unread: Boolean): String = when {
        session?.running == true -> if (session.live.text().isEmpty()) "thinking" else "streaming"
        session?.ending is Ending.Stopped -> "stopped"
        unread -> "unread"
        else -> "read"
    }

    private suspend fun create(params: JsonObject): JsonElement {
        val choice = chosen(params) ?: defaultChoice(providers.entries.value.filter { it.ready && it.definition.models.isNotEmpty() })
        if (providers.defaultModel == null && choice != MOCK) providers.defaultModel = choice.providerId to choice.modelId
        val created = runtime.command(buildJsonObject {
            put("action", "conversationCreate")
            putJsonObject("metadata") {}
        }) as JsonObject
        val number = ((created["reference"] as? JsonObject)?.get("conversationID") as? JsonPrimitive)?.intOrNull
            ?: throw HostError.Invalid("Conversation creation did not return its identity")
        remember(Session(number).apply {
            loaded = true
            this.choice = choice
            sessions[number] = this
        })
        OxLog.info("localHost.conversation.new", "conversation" to number, "provider" to choice.providerId, "model" to choice.modelId)
        return buildJsonObject {
            put("conversationId", identifier(number))
            put("temporary", false)
            put("model", choice.modelId)
        }
    }

    private suspend fun view(session: Session): JsonElement {
        load(session)
        val summary = (runtime.command(buildJsonObject {
            put("action", "applicationSummary")
            put("reference", reference(session.number))
        }) as JsonObject)["item"] as? JsonObject
        val unread = (summary?.get("unread") as? JsonPrimitive)?.booleanOrNull == true
        if (unread && !session.running) save(session) { put("unread", false) }
        return buildJsonObject {
            putJsonObject("data") {
                put("id", identifier(session.number))
                put("title", (summary?.get("presentation") as? JsonObject)?.text("title").orEmpty())
                put("providerId", session.choice.providerId)
                put("model", model(session.choice))
                put("temporary", false)
                put("blocks", blocks(session))
                put("isBusy", session.running)
                put("status", status(session, unread = false))
                when (val ending = session.ending) {
                    Ending.Stopped -> putJsonObject("turnEnding") { put("kind", "stopped") }
                    is Ending.Failed -> putJsonObject("turnEnding") {
                        put("kind", "failed")
                        put("message", ending.message)
                    }
                    null -> Unit
                }
                session.prompt?.let { prompt ->
                    putJsonObject("pendingPrompt") {
                        put("id", prompt.id)
                        put("prompt", prompt.text)
                        putJsonArray("options") {
                            add(ALLOW)
                            add(DENY)
                        }
                        put("allowsCustomAnswer", false)
                        put("requiresApp", false)
                    }
                }
                putJsonArray("followIntents") {}
                putJsonArray("queued") {
                    session.queue.forEach { queued ->
                        addJsonObject {
                            put("id", queued.id)
                            put("text", queued.text)
                            putJsonArray("attachments") {}
                        }
                    }
                }
                putJsonArray("services") { services.attached(session.number).sorted().forEach { add(it) } }
            }
        }
    }

    private fun blocks(session: Session): JsonArray {
        val messages = session.messages + listOfNotNull(session.interrupted, session.live)
        val results = messages.filter { it.text("role") == "toolResult" }.mapNotNull { result -> result.text("toolCallId")?.let { it to result } }.toMap()
        val blocks = mutableListOf<JsonObject>()
        val steps = mutableListOf<JsonObject>()
        var opened = 0.0
        var origin = 0
        var latest = 0.0
        fun flush(completed: Double?) {
            if (steps.isEmpty()) return
            val entries = JsonArray(steps.toList())
            steps.clear()
            blocks += buildJsonObject {
                put("id", "t$origin")
                put("createdAt", opened)
                putJsonObject("kind") {
                    put("type", "thinking")
                    putJsonObject("trace") {
                        put("entries", entries)
                        completed?.let { put("completedAt", it) }
                    }
                }
            }
        }
        messages.forEachIndexed { index, message ->
            val seconds = ((message["timestamp"] as? JsonPrimitive)?.longOrNull ?: 0L) / 1000.0
            latest = maxOf(latest, seconds)
            fun step(entry: JsonObject) {
                if (steps.isEmpty()) {
                    opened = seconds
                    origin = index
                }
                steps += entry
            }
            when (message.text("role")) {
                "user" -> {
                    flush(seconds)
                    blocks += buildJsonObject {
                        put("id", "m$index")
                        put("createdAt", seconds)
                        putJsonObject("kind") {
                            put("type", "userText")
                            put("text", message.text())
                            putJsonArray("attachments") {}
                        }
                    }
                }
                "assistant" -> {
                    val text = StringBuilder()
                    var part = 0
                    fun say() {
                        if (text.isEmpty()) return
                        val spoken = text.toString()
                        text.clear()
                        flush(seconds)
                        blocks += buildJsonObject {
                            put("id", if (part == 0) "m$index" else "m$index.$part")
                            put("createdAt", seconds)
                            putJsonObject("kind") {
                                put("type", "agentContent")
                                putJsonArray("items") { addJsonObject { put("text", spoken) } }
                            }
                        }
                        part += 1
                    }
                    (message["content"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().forEach { block ->
                        when (block.text("type")) {
                            "text" -> text.append(block.text("text").orEmpty())
                            "thinking" -> block.text("thinking")?.takeIf { it.isNotBlank() }?.let { thought ->
                                say()
                                step(buildJsonObject {
                                    put("kind", "reasoning")
                                    putJsonObject("reasoning") { put("text", thought) }
                                })
                            }
                            "toolCall" -> {
                                say()
                                step(invocation(block, results[block.text("id")], session.running))
                            }
                            else -> Unit
                        }
                    }
                    say()
                }
                else -> Unit
            }
        }
        flush(if (session.running) null else latest)
        return JsonArray(blocks)
    }

    private fun invocation(call: JsonObject, result: JsonObject?, running: Boolean) = buildJsonObject {
        put("kind", "invocation")
        putJsonObject("invocation") {
            put("name", call.text("name").orEmpty())
            put("purpose", (call["arguments"] as? JsonObject)?.text("purpose").orEmpty())
            putJsonObject("outcome") {
                when {
                    result == null && running -> putJsonObject("running") {}
                    result == null -> putJsonObject("failed") { put("_0", "Interrupted") }
                    (result["isError"] as? JsonPrimitive)?.booleanOrNull == true ->
                        putJsonObject("failed") { put("_0", result.text().lineSequence().lastOrNull { it.isNotBlank() }.orEmpty().removePrefix("[error] ").take(FAILURE_LENGTH)) }
                    else -> putJsonObject("succeeded") {}
                }
            }
        }
    }

    private suspend fun send(session: Session, params: JsonObject): JsonElement {
        val text = params.text("text").orEmpty()
        if ((params["attachments"] as? JsonArray).orEmpty().isNotEmpty() || params["skill"] is JsonPrimitive) {
            throw HostError.Rpc(INVALID_PARAMS, "Attachments and skills are not available on this device yet")
        }
        if (text.isBlank()) throw HostError.Rpc(INVALID_PARAMS, "provide a message")
        load(session)
        if (session.running) {
            session.queue += Queued(UUID.randomUUID().toString().uppercase(), text)
        } else {
            start(session, text)
        }
        OxLog.info("localHost.send", "conversation" to session.number, "chars" to text.length, "queued" to session.queue.size)
        return buildJsonObject {
            put("conversationId", identifier(session.number))
            put("outcome", "queued")
        }
    }

    private suspend fun start(session: Session, text: String) {
        session.ending = null
        session.interrupted = null
        session.streamed = null
        if (session.messages.isEmpty()) save(session) { put("title", text.lineSequence().first().take(TITLE_LENGTH)) }
        session.run = Run.Active(scope.launch { run(session, text) })
    }

    private suspend fun run(session: Session, text: String) {
        val started = System.nanoTime()
        var outcome = "failed"
        try {
            runtime.command(buildJsonObject {
                put("action", "attach")
                put("conversationID", session.number)
                put("config", configuration(session.choice, catalog.await()))
            })
            val result = runtime.command(buildJsonObject {
                put("action", "run")
                put("conversationID", session.number)
                put("requestID", UUID.randomUUID().toString())
                put("turnState", turnState(session.number, catalog.await()))
                putJsonArray("content") {
                    addJsonObject {
                        put("type", "text")
                        put("text", text)
                    }
                }
            }) as JsonObject
            val receipt = result["receipt"] as? JsonObject
            session.messages = conversational(result["messages"])
            outcome = receipt?.text("status") ?: "unknown"
            session.ending = when {
                outcome == "done" -> null
                receipt?.text("reason") == "aborted" -> Ending.Stopped
                else -> Ending.Failed(session.messages.lastOrNull()?.text("errorMessage") ?: "The reply did not finish")
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            session.ending = Ending.Failed(error.message?.lineSequence()?.firstOrNull() ?: "The reply failed")
        } finally {
            session.interrupted = (session.live ?: session.streamed)?.takeIf { session.ending is Ending.Stopped && it.text().isNotEmpty() }
            session.live = null
            session.run = Run.Idle
            OxLog.info("localHost.run.finished", "conversation" to session.number, "outcome" to outcome, "durationMs" to (System.nanoTime() - started) / 1_000_000)
        }
        val next = session.queue.firstOrNull() ?: return
        if (session.ending != null) return
        session.queue = session.queue.drop(1)
        start(session, next.text)
    }

    private suspend fun stop(session: Session): JsonElement {
        val running = session.running
        if (running) {
            session.queue = emptyList()
            runtime.command(buildJsonObject {
                put("action", "abort")
                put("conversationID", session.number)
            })
        }
        OxLog.info("localHost.stop", "conversation" to session.number, "wasRunning" to running)
        return buildJsonObject {
            put("conversationId", identifier(session.number))
            put("wasRunning", running)
        }
    }

    private suspend fun delete(session: Session): JsonElement {
        if (session.running) stop(session)
        (session.run as? Run.Active)?.job?.join()
        runtime.command(buildJsonObject {
            put("action", "applicationDelete")
            put("reference", reference(session.number))
        })
        sessions.remove(session.number)
        preferences.edit { remove("model.${session.number}") }
        files.forget(session.number)
        services.forget(session.number)
        OxLog.info("localHost.conversation.deleted", "conversation" to session.number)
        return JsonObject(emptyMap())
    }

    private suspend fun save(session: Session, change: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): JsonElement {
        runtime.command(buildJsonObject {
            put("action", "applicationSave")
            put("reference", reference(session.number))
            change()
        })
        return JsonObject(emptyMap())
    }

    private suspend fun load(session: Session) {
        if (session.loaded) return
        val context = runtime.command(buildJsonObject {
            put("action", "conversationContext")
            put("conversationID", session.number)
        }) as JsonObject
        session.messages = conversational(context["messages"])
        val item = (runtime.command(buildJsonObject {
            put("action", "applicationSummary")
            put("reference", reference(session.number))
        }) as JsonObject)["item"] as? JsonObject
        val modelId = ((item?.get("agent") as? JsonObject)?.get("model") as? JsonObject)?.text("modelId")
        val providerId = (item?.get("metadata") as? JsonObject)?.text("nativeProviderID")
        val kept = preferences.getString("model.${session.number}", null)?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() } as? JsonObject
        val keptProvider = kept?.text("providerId")
        val keptModel = kept?.text("modelId")
        if (keptProvider != null && keptModel != null) session.choice = Choice(keptProvider, keptModel, kept.text("effort")?.takeIf { effort ->
            providers.entry(keptProvider)?.definition?.let { provider -> provider.models.firstOrNull { it.id == keptModel }?.let { effort in efforts(provider, it) } } == true
        })
        else if (modelId != null && providerId != null) session.choice = Choice(providerId, modelId)
        session.loaded = true
    }

    private suspend fun native(method: String, params: JsonObject, stream: (JsonElement) -> Unit): JsonElement {
        if (method == "fileBackend") return files.perform(params)
        val number = (params["conversationID"] as? JsonPrimitive)?.intOrNull ?: throw AgentRuntimeException("Native conversation is not attached")
        return when (method) {
            "agentEvents" -> {
                val session = sessions[number]
                if (session != null) (params["events"] as? JsonArray).orEmpty().forEach { receive(session, it as JsonObject) }
                JsonNull
            }
            "nativeModel" -> {
                val choice = sessions[number]?.choice ?: MOCK
                val messages = (params["messages"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
                withContext(Dispatchers.Default) {
                    if (choice == MOCK) {
                        MockModel.stream(number, messages, stream)
                    } else {
                        val entry = providers.entry(choice.providerId) ?: throw AgentRuntimeException("${choice.providerId} is no longer configured")
                        val model = definition(choice) ?: throw AgentRuntimeException("${choice.modelId} is no longer available")
                        val credential = try {
                            providers.credential(choice.providerId)
                        } catch (error: ChatGptFailure) {
                            null.also { OxLog.warning("localHost.credential.unavailable", "provider" to choice.providerId, "message" to error.message) }
                        }
                        transports.stream(
                            ModelRequest(
                                number, entry.definition, model, credential, identifier(number), choice.effort, params.text("systemPrompt").orEmpty(), messages,
                                (params["tools"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>(),
                                ((params["streamOptions"] as? JsonObject)?.get("maxTokens") as? JsonPrimitive)?.intOrNull?.takeIf { it > 0 },
                            ),
                            stream,
                        )
                    }
                }
                JsonNull
            }
            "nativeTool" -> {
                if (params.text("name") != ToolCatalog.EXECUTE) throw AgentRuntimeException("Unknown tool ${params.text("name")}")
                tools.await().execute(number, params["arguments"] as? JsonObject ?: JsonObject(emptyMap()))
            }
            else -> throw AgentRuntimeException("Unavailable native capability $method")
        }
    }

    private fun receive(session: Session, event: JsonObject) {
        when (event.text("type")) {
            "message_start" -> (event["message"] as? JsonObject)?.let { message ->
                if (message.text("role") == "assistant") session.live = message
            }
            "message_update" -> session.live = event["partial"] as? JsonObject
                ?: (event["changes"] as? JsonArray).orEmpty().fold(session.live) { live, change -> live?.let { applied(it, change as JsonObject) } }
            "message_end" -> {
                val committed = conversational((event["entry"] as? JsonObject)?.get("model"))
                session.messages += committed
                if (committed.any { it.text("role") == "assistant" }) {
                    session.streamed = session.live
                    session.live = null
                }
            }
            else -> Unit
        }
    }

    private fun applied(message: JsonObject, change: JsonObject): JsonObject {
        val index = (change["contentIndex"] as? JsonPrimitive)?.intOrNull ?: return message
        val field = when (change.text("type")) {
            "text_delta" -> "text"
            "thinking_delta" -> "thinking"
            else -> return message
        }
        val content = (message["content"] as? JsonArray).orEmpty()
        val block = content.getOrNull(index) as? JsonObject ?: return message
        val updated = JsonObject(block + (field to JsonPrimitive(block.text(field).orEmpty() + change.text("delta").orEmpty())))
        return JsonObject(message + ("content" to JsonArray(content.toMutableList().apply { set(index, updated) })))
    }

    private suspend fun serviceRows(): JsonElement {
        val catalog = services.catalog()
        icons.warm(catalog.mapNotNull { it.manifest.string("faviconUrl") })
        return buildJsonObject {
            putJsonArray("services") {
                catalog.forEach { service ->
                    addJsonObject {
                        put("domain", service.domain)
                        put("title", service.name)
                        put("phase", "ready")
                        put("signIn", if (service.sessions) "unknown" else "notRequired")
                        put("favicon", icons.cached(service.manifest.string("faviconUrl")))
                    }
                }
            }
        }
    }

    private suspend fun respond(session: Session, params: JsonObject): JsonElement {
        val prompt = session.prompt?.takeIf { it.id == params.text("promptId") } ?: throw HostError.Rpc(INVALID_PARAMS, "This question is no longer waiting for an answer")
        val answer = params.text("answer").orEmpty()
        prompt.answer.complete(answer)
        OxLog.info("localHost.prompt.answered", "conversation" to session.number, "allowed" to (answer == ALLOW))
        return buildJsonObject {
            put("conversationId", identifier(session.number))
            put("promptId", prompt.id)
        }
    }

    private suspend fun confirm(conversation: Int, text: String): Boolean = withContext(serial) {
        val session = sessions[conversation] ?: return@withContext false
        val prompt = Prompt(UUID.randomUUID().toString().uppercase(), text, CompletableDeferred())
        session.prompt = prompt
        OxLog.info("localHost.prompt.asked", "conversation" to conversation)
        try {
            prompt.answer.await() == ALLOW
        } finally {
            if (session.prompt === prompt) session.prompt = null
        }
    }

    private fun asset(name: String) = application.assets.open("agent/$name").bufferedReader().use { it.readText() }

    private fun hostContext(catalog: ToolCatalog) = buildJsonObject {
        putJsonObject("active") {
            put("hostID", HOST_ID)
            put("profileID", profileId)
        }
        putJsonArray("hosts") {
            addJsonObject {
                put("hostID", HOST_ID)
                put("profileID", profileId)
                putJsonArray("functions") { catalog.names.forEach { add(it) } }
                putJsonArray("serviceKinds") { add("web") }
                put("presentation", "conversation-bubbles")
                put("externalFiles", false)
            }
        }
    }

    private suspend fun turnState(conversation: Int, catalog: ToolCatalog) = buildJsonObject {
        putJsonArray("skills") {
            ServiceBundle.skills(bundle).forEach { (name, description) ->
                addJsonObject {
                    put("name", name)
                    put("description", description)
                }
            }
        }
        putJsonArray("skillConflicts") {}
        putJsonArray("services") {
            services.attachedServices(conversation).forEach { service ->
                addJsonObject {
                    put("domain", service.domain)
                    service.description?.let { put("description", it) }
                }
            }
        }
        putJsonArray("filePaths") {}
        putJsonArray("fileRoots") { FILE_ROOTS.forEach { add(it) } }
        put("storageMode", "persisted")
        put("responseLanguage", JsonNull)
        put("hostContext", hostContext(catalog))
    }

    private fun configuration(choice: Choice, catalog: ToolCatalog) = buildJsonObject {
        val model = definition(choice)
        put("model", choice.modelId)
        putJsonObject("promptState") {
            put("memory", "")
            put("hostContext", hostContext(catalog))
        }
        put("isolatedFiles", false)
        put("providerID", choice.providerId)
        put("thinkingLevel", JsonNull)
        put("nativeReasoningEffort", JsonNull)
        put("contextWindow", model?.contextTokens ?: 200_000)
        put("maxTokens", model?.outputTokens ?: 8_192)
        put("reasoning", false)
        put("systemUpdates", false)
        put("toolExecutionMode", "sequential")
        putJsonArray("tools") { add(catalog.tool) }
        putJsonArray("messages") {}
    }

    private fun session(params: JsonObject): Session {
        val id = params.text("conversationId") ?: throw HostError.Rpc(INVALID_PARAMS, "provide a conversation")
        val number = number(id) ?: throw HostError.Rpc(INVALID_PARAMS, "unknown conversation: $id")
        return sessions.getOrPut(number) { Session(number) }
    }

    private fun reference(number: Int) = buildJsonObject {
        put("profileID", profileId)
        put("conversationID", number)
    }

    private fun identifier(number: Int): String {
        val compact = profileId.replace("-", "").take(16) + "%016x".format(number.toLong())
        return listOf(compact.substring(0, 8), compact.substring(8, 12), compact.substring(12, 16), compact.substring(16, 20), compact.substring(20, 32))
            .joinToString("-").uppercase()
    }

    private fun number(identifier: String): Int? {
        val compact = identifier.replace("-", "")
        if (compact.length != 32 || !compact.take(16).equals(profileId.replace("-", "").take(16), ignoreCase = true)) return null
        return compact.takeLast(16).toLongOrNull(16)?.takeIf { it in 0..Int.MAX_VALUE }?.toInt()
    }

    private fun conversational(messages: JsonElement?): List<JsonObject> =
        (messages as? JsonArray).orEmpty().filterIsInstance<JsonObject>().filter { it.text("role") != "system" }

    private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject?.text(): String =
        (this?.get("content") as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.takeIf { block -> block.text("type") == "text" }?.text("text") }.joinToString("")

    private companion object {
        const val PROFILE_KEY = "profileId"
        val MOCK = Choice(MockModel.ID, MockModel.ID)
        const val RPC_VERSION = 5
        const val LIST_PAGE = 100
        const val TITLE_LENGTH = 60
        const val FAILURE_LENGTH = 200
        const val HOST_ID = "android"
        val FILE_ROOTS = listOf("files", "repositories", "skills", "tmp")
        const val ALLOW = "Allow"
        const val DENY = "Deny"
        const val METHOD_NOT_FOUND = -32601
        const val INVALID_PARAMS = -32602
        const val INTERNAL_ERROR = -32603
        val METHODS = listOf(
            "profile.describe", "providers.list", "conversations.list", "conversations.new", "conversations.view", "conversations.send",
            "conversations.stop", "conversations.respond", "conversations.setServices", "conversations.setModel", "services.list", "conversations.rename", "conversations.pin", "conversations.delete",
        )
    }
}
