package ai.openox.ox.client.features.conversation

import ai.openox.ox.client.ui.Toast
import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.remote.ConversationSnapshot
import ai.openox.ox.remote.ConversationView
import ai.openox.ox.remote.FollowIntent
import ai.openox.ox.remote.HostClient
import ai.openox.ox.remote.HostError
import ai.openox.ox.remote.PendingPrompt
import ai.openox.ox.remote.QueuedMessage
import ai.openox.ox.remote.SendOutcome
import ai.openox.ox.remote.TurnEnding
import ai.openox.ox.remote.Upload
import android.os.SystemClock
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

class Attachment(val id: Long, val name: String, val bytes: ByteArray)

data class ChatModel(val providerId: String, val modelId: String, val name: String, val effort: String? = null)

sealed interface RunPhase {
    data object Idle : RunPhase
    data object Sending : RunPhase
    data class AwaitingStart(val blockCount: Int, val since: Long) : RunPhase
    data object Running : RunPhase
    data object Stopping : RunPhase

    val isActive: Boolean get() = this != Idle
}

sealed interface LoadState {
    data object Loading : LoadState
    data object Ready : LoadState
    data class Failed(val message: String) : LoadState
}

data class Notice(val message: String, val connection: Boolean)

data class ChatState(
    val conversationId: String?,
    val load: LoadState,
    val title: String? = null,
    val model: ChatModel? = null,
    val temporary: Boolean = false,
    val items: List<TranscriptItem> = emptyList(),
    val pendingPrompt: PendingPrompt? = null,
    val turnEnding: TurnEnding? = null,
    val followIntents: List<FollowIntent> = emptyList(),
    val queued: List<QueuedMessage> = emptyList(),
    val services: List<String> = emptyList(),
    val parentId: String? = null,
    val parentTitle: String? = null,
    val phase: RunPhase = RunPhase.Idle,
    val editing: TranscriptItem.UserText? = null,
    val notice: Notice? = null,
) {
    val isDraft: Boolean get() = conversationId == null || (items.isEmpty() && queued.isEmpty() && !phase.isActive)
}

sealed interface ChatEvent {
    data class Open(val conversationId: String) : ChatEvent
    data object Deleted : ChatEvent
    data class Toast(val message: String) : ChatEvent
    data class File(val name: String, val bytes: ByteArray) : ChatEvent
}

class ChatViewModel(private val client: HostClient, initialId: String?, defaultModel: ChatModel?) : ViewModel() {
    private val _state = MutableStateFlow(
        ChatState(conversationId = initialId, load = if (initialId == null) LoadState.Ready else LoadState.Loading, model = defaultModel),
    )
    val state: StateFlow<ChatState> = _state.asStateFlow()

    val draft = TextFieldState()

    private val _attachments = MutableStateFlow<List<Attachment>>(emptyList())
    val attachments: StateFlow<List<Attachment>> = _attachments.asStateFlow()

    private val _events = Channel<ChatEvent>(Channel.BUFFERED)
    val events = _events.receiveAsFlow()

    private var blocks: List<JsonObject> = emptyList()
    private var attachmentSequence = 0L
    private val useView = client.supports("conversations.view")

    val capabilities = Capabilities(client)

    fun updateDraft(value: String) {
        draft.setTextAndPlaceCursorAtEnd(value)
    }

    fun appendDraft(value: String) {
        updateDraft(listOf(draft.text.toString(), value).filter { it.isNotBlank() }.joinToString(" "))
    }

    fun offerDefaultModel(model: ChatModel?) {
        if (model != null) _state.update { if (it.isDraft && it.model == null) it.copy(model = model) else it }
    }

    suspend fun observe() {
        if (_state.value.conversationId != null) {
            if (_state.value.load is LoadState.Ready) refresh() else load()
        }
        _state.map { it.phase.isActive }.distinctUntilChanged().collectLatest { active ->
            while (true) {
                delay(if (active) ACTIVE_POLL else IDLE_POLL)
                if (_state.value.load is LoadState.Ready && _state.value.conversationId != null) refresh()
            }
        }
    }

    fun reload() {
        _state.update { it.copy(load = LoadState.Loading) }
        viewModelScope.launch { load() }
    }

    fun chooseModel(model: ChatModel) {
        val id = _state.value.conversationId
        OxLog.info("chat.model", "provider" to model.providerId, "model" to model.modelId, "effort" to model.effort, "existing" to (id != null))
        if (id == null) {
            _state.update { if (it.isDraft) it.copy(model = model) else it }
        } else if (capabilities.setModel) {
            perform("conversation.model") { client.setModel(id, model.providerId, model.modelId, model.effort) }
        }
    }

    fun setTemporary(temporary: Boolean) {
        _state.update { if (it.conversationId == null) it.copy(temporary = temporary) else it }
    }

    fun addAttachments(files: List<Pair<String, ByteArray>>) {
        _attachments.update { current -> current + files.map { (name, bytes) -> Attachment(++attachmentSequence, name, bytes) } }
    }

    fun removeAttachment(attachment: Attachment) {
        _attachments.update { current -> current.filterNot { it.id == attachment.id } }
    }

    fun toggleService(domain: String) {
        val next = _state.value.services.let { if (domain in it) it - domain else it + domain }
        _state.update { it.copy(services = next) }
        val id = _state.value.conversationId ?: return
        perform("conversation.services") { client.setServices(id, next) }
    }

    fun beginEdit(item: TranscriptItem.UserText) {
        if (!capabilities.edit) return
        _state.update { it.copy(editing = item) }
        draft.setTextAndPlaceCursorAtEnd(item.text)
    }

    fun cancelEdit() {
        _state.update { it.copy(editing = null) }
        draft.clearText()
    }

    fun send(skills: Set<String> = emptySet()) {
        val text = draft.text.toString().trim()
        val ready = _state.value
        val files = _attachments.value
        if ((text.isEmpty() && files.isEmpty()) || ready.phase == RunPhase.Sending || ready.phase == RunPhase.Stopping) return
        ready.editing?.let { item ->
            submitEdit(item, text)
            return
        }
        val skill = SKILL.find(text)?.takeIf { it.groupValues[1] in skills }
        val message = skill?.let { text.removePrefix(it.value).trim() } ?: text
        draft.clearText()
        _attachments.value = emptyList()
        setPhase(RunPhase.Sending)
        viewModelScope.launch {
            val before = blocks.size
            try {
                val id = ensureConversation()
                val result = client.send(id, message, files.map { Upload(it.name, it.bytes) }, skill?.groupValues?.get(1))
                OxLog.info("conversation.send", "id" to id, "outcome" to result.outcome, "length" to message.length, "attachments" to files.size, "skill" to skill?.groupValues?.get(1))
                when (result.outcome) {
                    SendOutcome.Queued, SendOutcome.Completed, SendOutcome.NeedsAttention ->
                        setPhase(RunPhase.AwaitingStart(blocks.size, SystemClock.elapsedRealtime()))
                    SendOutcome.Failed, SendOutcome.Cancelled -> {
                        restore(text, files)
                        setPhase(RunPhase.Idle, Notice(result.error ?: "The message was not sent", connection = false))
                    }
                }
                refresh()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val delivered = error is HostError.Unavailable && error.sent && arrived(before)
                OxLog.warning("conversation.send.failed", "message" to error.message, "delivered" to delivered)
                if (delivered) {
                    setPhase(RunPhase.AwaitingStart(before, SystemClock.elapsedRealtime()))
                    refresh()
                } else {
                    restore(text, files)
                    setPhase(RunPhase.Idle, Notice(error.message ?: "The message was not sent", connection = false))
                }
            }
        }
    }

    fun sendText(text: String) {
        draft.setTextAndPlaceCursorAtEnd(text)
        send()
    }

    fun resume() = sendText(CONTINUE)

    fun stop() {
        val id = _state.value.conversationId ?: return
        if (_state.value.phase != RunPhase.Running && _state.value.phase !is RunPhase.AwaitingStart) return
        setPhase(RunPhase.Stopping)
        viewModelScope.launch {
            try {
                val result = client.stop(id)
                OxLog.info("conversation.stop", "id" to id, "wasRunning" to result.wasRunning)
                refresh()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                setPhase(RunPhase.Running, Notice(error.message ?: "Could not stop the reply", connection = false))
            }
        }
    }

    fun respond(prompt: PendingPrompt, answer: String) {
        val id = _state.value.conversationId ?: return
        perform("conversation.respond") {
            client.respond(id, prompt.id, answer)
            setPhase(RunPhase.Running)
        }
    }

    fun retryFailed() {
        val id = _state.value.conversationId ?: return
        perform("conversation.retryFailed") {
            client.retryFailed(id)
            setPhase(RunPhase.AwaitingStart(blocks.size, SystemClock.elapsedRealtime()))
        }
    }

    fun retry(item: TranscriptItem.AgentContent) {
        val id = _state.value.conversationId ?: return
        setPhase(RunPhase.Sending)
        perform("conversation.retry") {
            adopt(client.retry(id, item.id))
            setPhase(RunPhase.AwaitingStart(0, SystemClock.elapsedRealtime()))
        }
    }

    fun branch(item: TranscriptItem.AgentContent) {
        val id = _state.value.conversationId ?: return
        perform("conversation.branch") { _events.send(ChatEvent.Open(client.branch(id, item.id))) }
    }

    fun cancelQueued(message: QueuedMessage) {
        val id = _state.value.conversationId ?: return
        perform("conversation.cancelQueued") { client.cancelQueued(id, message.id) }
    }

    fun rename(title: String) {
        val id = _state.value.conversationId ?: return
        _state.update { it.copy(title = title) }
        perform("conversation.rename") { client.rename(id, title) }
    }

    fun delete() {
        val id = _state.value.conversationId ?: return
        perform("conversation.delete") {
            client.delete(id)
            _events.send(ChatEvent.Deleted)
        }
    }

    fun open(file: FileRef) {
        val id = _state.value.conversationId ?: return
        perform("conversation.file") { _events.send(ChatEvent.File(file.name, client.download(id, file.path, file.attachmentId))) }
    }

    fun toast(message: String) {
        viewModelScope.launch { _events.send(ChatEvent.Toast(message)) }
    }

    fun dismissNotice() = notice(null)

    fun transcriptText(): String = _state.value.items.mapNotNull { item ->
        when (item) {
            is TranscriptItem.UserText -> "**You:** ${item.text}"
            is TranscriptItem.AgentContent -> item.parts.filterIsInstance<AgentPart.Text>().joinToString("\n\n") { it.markdown.trim() }.ifBlank { null }
            else -> null
        }
    }.joinToString("\n\n")

    private fun submitEdit(item: TranscriptItem.UserText, text: String) {
        val id = _state.value.conversationId ?: return
        draft.clearText()
        _state.update { it.copy(editing = null) }
        setPhase(RunPhase.Sending)
        perform("conversation.edit") {
            adopt(client.edit(id, item.id, text))
            setPhase(RunPhase.AwaitingStart(0, SystemClock.elapsedRealtime()))
        }
    }

    private suspend fun ensureConversation(): String {
        _state.value.conversationId?.let { return it }
        val current = _state.value
        val created = client.newConversation(current.model?.providerId, current.model?.modelId, current.temporary, current.model?.effort)
        OxLog.info("conversation.new", "id" to created.conversationId, "model" to created.model, "temporary" to created.temporary)
        _state.update { it.copy(conversationId = created.conversationId) }
        if (current.services.isNotEmpty()) client.setServices(created.conversationId, current.services)
        return created.conversationId
    }

    private suspend fun arrived(before: Int): Boolean {
        refresh()
        return blocks.size > before || _state.value.queued.isNotEmpty()
    }

    private suspend fun adopt(id: String) {
        blocks = emptyList()
        _state.update { it.copy(conversationId = id, items = emptyList()) }
        refresh()
    }

    private fun restore(text: String, files: List<Attachment>) {
        if (draft.text.isEmpty()) draft.setTextAndPlaceCursorAtEnd(text)
        if (_attachments.value.isEmpty()) _attachments.value = files
    }

    private fun perform(event: String, action: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                action()
                OxLog.info(event, "id" to _state.value.conversationId)
                refresh()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                OxLog.warning("$event.failed", "id" to _state.value.conversationId, "message" to error.message)
                setPhase(if (_state.value.phase == RunPhase.Sending) RunPhase.Idle else _state.value.phase, Notice(error.message ?: "Something went wrong", connection = false))
            }
        }
    }

    private suspend fun load() {
        val id = _state.value.conversationId ?: return
        try {
            if (useView) apply(client.viewConversation(id)) else applySnapshot(client.openConversation(id).let { it.id to it }, opened = true)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            OxLog.warning("conversation.open.failed", "id" to id, "message" to error.message)
            _state.update { it.copy(load = LoadState.Failed(error.message ?: "Could not open the conversation")) }
        }
    }

    private suspend fun refresh() {
        val id = _state.value.conversationId ?: return
        try {
            if (useView) apply(client.viewConversation(id)) else applySnapshot(client.getConversation(id).let { it.id to it }, opened = false)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            OxLog.warning("conversation.refresh.failed", "id" to id, "message" to error.message)
            notice(Notice(error.message ?: "Lost the Host connection", connection = true))
        }
    }

    private fun apply(view: ConversationView) {
        if (!view.id.equals(_state.value.conversationId, ignoreCase = true)) {
            OxLog.info("conversation.view.stale", "id" to view.id, "current" to _state.value.conversationId)
            return
        }
        val old = blocks
        val changed = view.blocks != old
        if (changed) blocks = view.blocks
        _state.update { previous ->
            previous.copy(
                conversationId = view.id,
                load = LoadState.Ready,
                title = view.title.ifBlank { null },
                model = modelOf(view.providerId, view.model) ?: previous.model,
                temporary = view.temporary,
                items = if (changed || previous.items.isEmpty()) Transcript.items(blocks, old, previous.items) else previous.items,
                pendingPrompt = view.pendingPrompt,
                turnEnding = view.turnEnding,
                followIntents = view.followIntents,
                queued = view.queued,
                services = view.services,
                parentId = view.parentId,
                parentTitle = view.parentTitle,
                phase = nextPhase(previous.phase, view.isBusy, view.blocks.size, view.pendingPrompt != null),
                notice = previous.notice?.takeUnless { it.connection },
            )
        }
    }

    private fun applySnapshot(pair: Pair<String, ConversationSnapshot>, opened: Boolean) {
        val snapshot = pair.second
        val old = blocks
        val changed = snapshot.blocks != old
        if (changed) blocks = snapshot.blocks
        _state.update { previous ->
            previous.copy(
                load = LoadState.Ready,
                model = modelOf(null, snapshot.model) ?: previous.model,
                items = if (changed || opened) Transcript.items(blocks, old, previous.items) else previous.items,
                pendingPrompt = snapshot.pendingPrompt,
                phase = nextPhase(previous.phase, snapshot.isBusy, snapshot.blocks.size, snapshot.pendingPrompt != null),
                notice = previous.notice?.takeUnless { it.connection },
            )
        }
    }

    private fun modelOf(providerId: String?, model: JsonObject): ChatModel? {
        val id = (model["id"] as? JsonPrimitive)?.contentOrNull ?: return null
        val name = (model["displayName"] as? JsonPrimitive)?.contentOrNull ?: id
        return ChatModel(providerId ?: "", id, name, (model["reasoningEffort"] as? JsonPrimitive)?.contentOrNull)
    }

    private fun nextPhase(current: RunPhase, busy: Boolean, blockCount: Int, prompting: Boolean): RunPhase = when {
        current == RunPhase.Sending -> current
        busy -> if (current == RunPhase.Stopping) current else RunPhase.Running
        current is RunPhase.AwaitingStart ->
            if (blockCount > current.blockCount + 1 || prompting ||
                SystemClock.elapsedRealtime() - current.since > START_GRACE.inWholeMilliseconds
            ) RunPhase.Idle else current
        else -> RunPhase.Idle
    }

    private fun setPhase(phase: RunPhase, notice: Notice? = null) {
        _state.update { it.copy(phase = phase, notice = notice ?: it.notice) }
    }

    private fun notice(notice: Notice?) {
        _state.update { it.copy(notice = notice) }
    }

    class Capabilities(client: HostClient) {
        val edit = client.supports("conversations.edit")
        val retry = client.supports("conversations.retry")
        val branch = client.supports("conversations.branch")
        val delete = client.supports("conversations.delete")
        val rename = client.supports("conversations.rename")
        val attachments = client.supports("conversations.view")
        val services = client.supports("conversations.setServices")
        val setModel = client.supports("conversations.setModel")
        val retryFailed = client.supports("conversations.retryFailed")
        val cancelQueued = client.supports("conversations.cancelQueued")
    }

    private companion object {
        val ACTIVE_POLL = 350.milliseconds
        val IDLE_POLL = 3.seconds
        val START_GRACE = 8.seconds
        val SKILL = Regex("""^/([a-z0-9][a-z0-9-]*)(\s|$)""")
        const val CONTINUE = "Continue"
    }
}
