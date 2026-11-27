package ai.openox.ox.client

import ai.openox.ox.client.features.conversation.ChatModel
import ai.openox.ox.client.ui.Toast
import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.LocalHost
import ai.openox.ox.platform.models.HostEndpoint
import ai.openox.ox.remote.ConversationRow
import ai.openox.ox.remote.HostClient
import ai.openox.ox.remote.HostConnection
import ai.openox.ox.remote.ProfileDescription
import ai.openox.ox.remote.ProviderRow
import ai.openox.ox.remote.ServiceRow
import ai.openox.ox.remote.SkillRow
import android.app.Application
import androidx.core.content.edit
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

sealed interface HostState {
    data object NotConfigured : HostState
    data class Connecting(val endpoint: HostEndpoint) : HostState
    data class Connected(val endpoint: HostEndpoint, val description: ProfileDescription, val client: HostClient) : HostState
    data class Failed(val endpoint: HostEndpoint, val message: String) : HostState
}

sealed interface ConversationListState {
    data object Loading : ConversationListState
    data class Loaded(val rows: List<ConversationRow>, val refreshError: String? = null) : ConversationListState
    data class Failed(val message: String) : ConversationListState
}

sealed interface ProvidersState {
    data object Idle : ProvidersState
    data object Loading : ProvidersState
    data class Loaded(val providers: List<ProviderRow>, val defaultModel: ChatModel?) : ProvidersState
    data class Failed(val message: String) : ProvidersState
}

sealed interface HostEvent {
    data class Completed(val row: ConversationRow) : HostEvent
    data class Toast(val message: String, val error: Boolean) : HostEvent
}

class HostViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences("host", Application.MODE_PRIVATE)
    private val http = OkHttpClient.Builder().pingInterval(KEEPALIVE_SECONDS, TimeUnit.SECONDS).build()
    private var connection: Job? = null
    private var lastStatuses: Map<String, String> = emptyMap()

    private val _host = MutableStateFlow<HostState>(HostState.NotConfigured)
    val host: StateFlow<HostState> = _host.asStateFlow()

    private val _conversations = MutableStateFlow<ConversationListState>(ConversationListState.Loading)
    val conversations: StateFlow<ConversationListState> = _conversations.asStateFlow()

    private val _providers = MutableStateFlow<ProvidersState>(ProvidersState.Idle)
    val providers: StateFlow<ProvidersState> = _providers.asStateFlow()

    private val _skills = MutableStateFlow<List<SkillRow>>(emptyList())
    val skills: StateFlow<List<SkillRow>> = _skills.asStateFlow()

    private val _services = MutableStateFlow<List<ServiceRow>>(emptyList())
    val services: StateFlow<List<ServiceRow>> = _services.asStateFlow()

    private val _events = Channel<HostEvent>(Channel.BUFFERED)
    val events = _events.receiveAsFlow()

    var openConversationId: String? = null

    val savedAddress: String get() = preferences.getString(ENDPOINT_KEY, null).orEmpty()

    val remoteAddress: String get() = savedAddress.takeUnless { it == HostEndpoint.Local.url }.orEmpty()

    fun useThisDevice() = connect(HostEndpoint.Local)

    init {
        HostEndpoint.parse(savedAddress).onSuccess(::connect)
    }

    fun connect(address: String): Result<Unit> = HostEndpoint.parse(address).map(::connect)

    fun forget() {
        connection?.cancel()
        currentClient()?.close()
        preferences.edit { remove(ENDPOINT_KEY) }
        _host.value = HostState.NotConfigured
        _conversations.value = ConversationListState.Loading
        _providers.value = ProvidersState.Idle
        OxLog.info("host.forget")
    }

    fun retry() {
        when (val state = _host.value) {
            is HostState.Failed -> connect(state.endpoint)
            is HostState.Connected -> refreshConversations()
            else -> Unit
        }
    }

    fun supports(method: String): Boolean = currentClient()?.supports(method) == true

    suspend fun observeHost() {
        (_host.value as? HostState.Failed)?.let { failed ->
            OxLog.info("host.foreground.reconnect", "endpoint" to failed.endpoint)
            connect(failed.endpoint)
        }
        while (true) {
            currentClient()?.let { loadConversations(it) }
            delay(LIST_POLL)
        }
    }

    fun refreshConversations() {
        val client = currentClient() ?: return
        viewModelScope.launch { loadConversations(client) }
    }

    fun loadProviders() {
        val client = currentClient() ?: return
        if (_providers.value is ProvidersState.Loading || _providers.value is ProvidersState.Loaded) return
        _providers.value = ProvidersState.Loading
        viewModelScope.launch {
            _providers.value = try {
                val result = client.listProviders()
                val providers = result.providers.filter { it.models.isNotEmpty() }
                val default = result.defaultModel?.let { selected ->
                    providers.firstOrNull { it.id == selected.providerId }?.models?.firstOrNull { it.id == selected.modelId }
                        ?.let { ChatModel(selected.providerId, it.id, it.displayName) }
                }
                ProvidersState.Loaded(providers, default)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                ProvidersState.Failed(error.message ?: "Could not load models")
            }
        }
    }

    fun reloadProviders() {
        _providers.value = ProvidersState.Idle
        loadProviders()
    }

    fun loadSkills() = load("skills.list") { client ->
        _skills.value = client.listSkills()
        OxLog.info("skills.loaded", "count" to _skills.value.size)
    }

    fun loadServices() = load("services.list") { client -> _services.value = client.listServices().sortedBy { it.title.lowercase() } }

    fun reloadService(service: ServiceRow) = serviceAction("services.reload", service) { it.reloadService(service.domain) }

    fun refreshServiceAuth(service: ServiceRow) = serviceAction("services.refreshAuth", service) { it.refreshServiceAuth(service.domain) }

    private fun serviceAction(event: String, service: ServiceRow, action: suspend (HostClient) -> Unit) {
        val client = currentClient() ?: return
        viewModelScope.launch {
            try {
                action(client)
                OxLog.info(event, "domain" to service.domain)
                _events.send(HostEvent.Toast(service.title, error = false))
                _services.value = client.listServices().sortedBy { it.title.lowercase() }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$event.failed", "domain" to service.domain, "message" to error.message)
                _events.send(HostEvent.Toast(error.message ?: "Something went wrong", error = true))
            }
        }
    }

    fun pin(row: ConversationRow) = mutate("conversation.pin") { it.pin(row.id, !row.pinned) }

    fun rename(row: ConversationRow, title: String) = mutate("conversation.rename") { it.rename(row.id, title) }

    fun delete(row: ConversationRow) {
        _conversations.update { state -> if (state is ConversationListState.Loaded) state.copy(rows = state.rows.filterNot { it.id == row.id }) else state }
        mutate("conversation.delete") { it.delete(row.id) }
    }

    private fun load(method: String, action: suspend (HostClient) -> Unit) {
        val client = currentClient() ?: return
        if (!client.supports(method)) return
        viewModelScope.launch {
            try {
                action(client)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$method.failed", "message" to error.message)
            }
        }
    }

    private fun mutate(event: String, action: suspend (HostClient) -> Unit) {
        val client = currentClient() ?: return
        viewModelScope.launch {
            try {
                action(client)
                OxLog.info(event)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$event.failed", "message" to error.message)
                _events.send(HostEvent.Toast(error.message ?: "Something went wrong", error = true))
            }
            loadConversations(client)
        }
    }

    private fun connect(endpoint: HostEndpoint) {
        connection?.cancel()
        currentClient()?.close()
        _host.value = HostState.Connecting(endpoint)
        _conversations.value = ConversationListState.Loading
        _providers.value = ProvidersState.Idle
        lastStatuses = emptyMap()
        val client = HostClient(endpoint, when (endpoint) {
            is HostEndpoint.Remote -> HostConnection(endpoint, http, HostClient.json)
            HostEndpoint.Local -> LocalHost(getApplication())
        })
        connection = viewModelScope.launch {
            try {
                val description = client.describe()
                preferences.edit { putString(ENDPOINT_KEY, endpoint.url) }
                OxLog.info(
                    "host.connected",
                    "endpoint" to endpoint,
                    "implementation" to description.implementation.name,
                    "version" to description.implementation.version,
                    "methods" to description.methods.size,
                )
                _host.value = HostState.Connected(endpoint, description, client)
                loadConversations(client)
                loadProviders()
                loadSkills()
                loadServices()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                client.close()
                OxLog.warning("host.connect.failed", "endpoint" to endpoint, "message" to error.message)
                _host.value = HostState.Failed(endpoint, error.message ?: "Could not reach the Host")
            }
        }
    }

    private suspend fun loadConversations(client: HostClient) {
        val previous = _conversations.value
        try {
            val rows = client.listConversations().sortedByDescending { it.lastActivity ?: it.createdAt }
            announceCompletions(rows)
            _conversations.value = ConversationListState.Loaded(rows)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val message = error.message ?: "Could not load conversations"
            OxLog.warning("conversations.list.failed", "message" to message)
            _conversations.value = if (previous is ConversationListState.Loaded) previous.copy(refreshError = message)
            else ConversationListState.Failed(message)
        }
    }

    private suspend fun announceCompletions(rows: List<ConversationRow>) {
        val before = lastStatuses
        lastStatuses = rows.associate { it.id to it.status }
        if (before.isEmpty()) return
        rows.filter { row ->
            val was = before[row.id]
            row.id != openConversationId && row.unread && (was == "thinking" || was == "streaming")
        }.forEach { _events.send(HostEvent.Completed(it)) }
    }

    private fun currentClient(): HostClient? = (_host.value as? HostState.Connected)?.client

    override fun onCleared() {
        currentClient()?.close()
    }

    private companion object {
        const val ENDPOINT_KEY = "endpoint"
        const val KEEPALIVE_SECONDS = 15L
        val LIST_POLL = 4.seconds
    }
}
