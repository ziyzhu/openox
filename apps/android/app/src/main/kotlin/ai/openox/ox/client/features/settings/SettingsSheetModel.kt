package ai.openox.ox.client.features.settings

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.remote.FolderGrantRow
import ai.openox.ox.remote.HostClient
import ai.openox.ox.remote.LogRow
import ai.openox.ox.remote.ProfileRow
import ai.openox.ox.remote.RepositoryRow
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

sealed interface Loadable<out T> {
    data object Loading : Loadable<Nothing>
    data class Loaded<T>(val value: T) : Loadable<T>
    data class Failed(val message: String) : Loadable<Nothing>
}

data class MemoryDraft(val saved: String)

data class LogPage(val rows: List<LogRow>, val cursor: String?, val level: String?, val query: String)

class SettingsViewModel(private val client: HostClient) : ViewModel() {
    private val _profile = MutableStateFlow<Loadable<ProfileRow>>(Loadable.Loading)
    val profile: StateFlow<Loadable<ProfileRow>> = _profile.asStateFlow()

    private val _memory = MutableStateFlow<Loadable<MemoryDraft>>(Loadable.Loading)
    val memory: StateFlow<Loadable<MemoryDraft>> = _memory.asStateFlow()

    val memoryText = TextFieldState()

    private val _folders = MutableStateFlow<Loadable<List<FolderGrantRow>>>(Loadable.Loading)
    val folders: StateFlow<Loadable<List<FolderGrantRow>>> = _folders.asStateFlow()

    private val _repositories = MutableStateFlow<Loadable<List<RepositoryRow>>>(Loadable.Loading)
    val repositories: StateFlow<Loadable<List<RepositoryRow>>> = _repositories.asStateFlow()

    private val _logs = MutableStateFlow<Loadable<LogPage>>(Loadable.Loading)
    val logs: StateFlow<Loadable<LogPage>> = _logs.asStateFlow()

    private val _messages = Channel<String>(Channel.BUFFERED)
    val messages = _messages.receiveAsFlow()

    fun supports(method: String) = client.supports(method)

    fun loadProfile() = load(_profile, "profile.inspect") { client.inspectProfile().profile }

    fun renameProfile(name: String) = act("profile.update") {
        _profile.value = Loadable.Loaded(client.updateProfile(name = name).profile)
    }

    fun loadMemory() = load(_memory, "profile.inspect") {
        val text = client.inspectProfile().memory.orEmpty()
        memoryText.setTextAndPlaceCursorAtEnd(text)
        MemoryDraft(text)
    }

    fun saveMemory() {
        val draft = (_memory.value as? Loadable.Loaded)?.value ?: return
        val text = memoryText.text.toString()
        if (text == draft.saved) return
        act("profile.update.memory") {
            client.updateProfile(memory = text)
            _memory.value = Loadable.Loaded(draft.copy(saved = text))
            _messages.send("saved")
        }
    }

    fun loadFolders() = load(_folders, "files.list") { client.listFolders().folders }

    fun unmount(folder: FolderGrantRow) = act("files.unmount") {
        client.unmountFolder(folder.id)
        _folders.value = Loadable.Loaded(client.listFolders().folders)
    }

    fun loadRepositories() = load(_repositories, "repositories.list") { client.listRepositories() }

    fun loadLogs(level: String?, query: String) = load(_logs, "logs.list") {
        val page = client.logs(LOG_PAGE, null, level, query.ifBlank { null })
        LogPage(page.logs, page.nextCursor, level, query)
    }

    fun moreLogs() {
        val current = (_logs.value as? Loadable.Loaded)?.value ?: return
        val cursor = current.cursor ?: return
        act("logs.list.more") {
            val page = client.logs(LOG_PAGE, cursor, current.level, current.query.ifBlank { null })
            _logs.value = Loadable.Loaded(current.copy(rows = current.rows + page.logs, cursor = page.nextCursor))
        }
    }

    private fun <T> load(target: MutableStateFlow<Loadable<T>>, event: String, fetch: suspend () -> T) {
        if (target.value !is Loadable.Loaded) target.value = Loadable.Loading
        viewModelScope.launch {
            target.value = try {
                Loadable.Loaded(fetch())
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$event.failed", "message" to error.message)
                Loadable.Failed(error.message ?: "Could not load")
            }
        }
    }

    private fun act(event: String, action: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                action()
                OxLog.info(event)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$event.failed", "message" to error.message)
                _messages.send(error.message ?: "Something went wrong")
            }
        }
    }

    private companion object {
        const val LOG_PAGE = 200
    }
}
