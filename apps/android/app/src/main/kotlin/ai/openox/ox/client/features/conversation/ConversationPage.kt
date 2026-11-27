package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.android.Platform
import ai.openox.ox.client.ProvidersState
import ai.openox.ox.client.features.providers.ModelSheet
import ai.openox.ox.client.features.providers.ProvidersSheet
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.ConfirmDialog
import ai.openox.ox.client.ui.GlassCircleButton
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.NoticeToast
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.TextDialog
import ai.openox.ox.client.ui.Toast
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.FollowIntent
import ai.openox.ox.remote.QueuedMessage
import ai.openox.ox.remote.ServiceRow
import ai.openox.ox.remote.SkillRow
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

data class ChatEnvironment(
    val providers: ProvidersState,
    val skills: List<SkillRow>,
    val services: List<ServiceRow>,
    val loadProviders: () -> Unit,
    val loadServices: () -> Unit,
    val onProvidersChanged: (() -> Unit)?,
    val onOpenSidebar: () -> Unit,
    val onOpenConversation: (String) -> Unit,
    val onNewConversation: () -> Unit,
    val onConversationChanged: (String?) -> Unit,
)

@Composable
fun ChatScreen(model: ChatViewModel, environment: ChatEnvironment, platform: Platform) {
    val state by model.state.collectAsStateWithLifecycle()
    val attachments by model.attachments.collectAsStateWithLifecycle()
    val haptics = LocalHapticFeedback.current
    var steps by remember { mutableStateOf<TranscriptItem.Thinking?>(null) }
    var choosingModel by remember { mutableStateOf(false) }
    var choosingServices by remember { mutableStateOf(false) }
    var viewingService by remember { mutableStateOf<String?>(null) }
    var settingUpProviders by remember { mutableStateOf(false) }
    val attached = remember(state.services, environment.services) {
        state.services.map { domain -> environment.services.firstOrNull { it.domain == domain } ?: ServiceRow(domain = domain, title = domain, phase = "", signIn = "") }
    }
    LaunchedEffect(state.services.isNotEmpty()) {
        if (state.services.isNotEmpty() && environment.services.isEmpty()) environment.loadServices()
    }
    var confirmDelete by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    val defaultModel = (environment.providers as? ProvidersState.Loaded)?.defaultModel

    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(model, lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.observe() } }
    LaunchedEffect(defaultModel) { model.offerDefaultModel(defaultModel) }
    LaunchedEffect(state.conversationId) { environment.onConversationChanged(state.conversationId) }
    LaunchedEffect(model) {
        model.events.collect { event ->
            when (event) {
                is ChatEvent.Open -> environment.onOpenConversation(event.conversationId)
                ChatEvent.Deleted -> environment.onNewConversation()
                is ChatEvent.Toast -> platform.toast(event.message)
                is ChatEvent.File -> platform.openFile(event.name, event.bytes)
            }
        }
    }

    val actions = MessageActions(
        copy = { text ->
            platform.copy(text)
            haptics.performHapticFeedback(HapticFeedbackType.ContextClick)
            platform.toast(platform.string(R.string.message_copied))
        },
        share = platform::shareText,
        edit = if (model.capabilities.edit && !state.phase.isActive) model::beginEdit else null,
        branch = if (model.capabilities.branch && !state.phase.isActive) model::branch else null,
        retry = if (model.capabilities.retry && !state.phase.isActive) model::retry else null,
    )

    val attach = AttachOptions(
        camera = if (model.capabilities.attachments) platform::takePhoto else null,
        photos = if (model.capabilities.attachments) platform::pickPhotos else null,
        files = if (model.capabilities.attachments) platform::pickFiles else null,
        services = if (model.capabilities.services || state.conversationId == null) {
            { choosingServices = true }
        } else null,
    )

    LaunchedEffect(platform, model) { platform.onAttachments = model::addAttachments }
    LaunchedEffect(platform, model) { platform.onSpeech = model::appendDraft }

    var composerHeight by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    Box(Modifier.fillMaxSize().background(LocalOxColors.current.conversationSurface).imePadding()) {
        when (val load = state.load) {
            LoadState.Loading -> Unit
            is LoadState.Failed -> Column(
                Modifier.fillMaxSize().padding(OxSpacing.xl),
                verticalArrangement = Arrangement.spacedBy(OxSpacing.md, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(load.message, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center, modifier = Modifier.testTag("conversation.error"))
                ChipButton(stringResource(R.string.host_retry), "conversation.reload", style = ChipStyle.Primary, onClick = model::reload)
            }
            LoadState.Ready -> Transcript(
                state = state,
                actions = actions,
                bottomPadding = with(density) { composerHeight.toDp() },
                onSteps = { steps = it },
                onFile = model::open,
                onResume = model::resume,
                onRetryFailed = if (model.capabilities.retryFailed) model::retryFailed else null,
                onFollow = { model.sendText(it.message) },
                onCancelQueued = if (model.capabilities.cancelQueued) model::cancelQueued else null,
                onParent = environment.onOpenConversation,
            )
        }
        Header(
            state = state,
            canChangeModel = model.capabilities.setModel,
            canRename = model.capabilities.rename,
            canDelete = model.capabilities.delete,
            onSidebar = environment.onOpenSidebar,
            onModel = { choosingModel = true },
            onTemporary = { model.setTemporary(!state.temporary) },
            onCopy = { actions.copy(model.transcriptText()) },
            onExport = { platform.shareText(model.transcriptText()) },
            onRename = { renaming = true },
            onDelete = { confirmDelete = true },
        )
        Column(
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().onSizeChanged { composerHeight = it.height },
        ) {
            Column(Modifier.navigationBarsPadding()) {
                state.editing?.let { editing ->
                    EditingChip(onCancel = model::cancelEdit, modifier = Modifier.testTag("conversation.cancelEdit.${editing.id}"))
                }
                SkillSuggestions(model.draft.text.toString(), environment.skills) { skill -> model.updateDraft("/${skill.name} ") }
                if (model.capabilities.services || state.conversationId == null) {
                    ServiceSuggestions(model.draft.text.toString(), environment.services, state.services, environment.loadServices) { service, remaining ->
                        model.updateDraft(remaining)
                        model.toggleService(service.domain)
                    }
                }
                val prompt = state.pendingPrompt
                if (prompt != null) {
                    PromptDock(prompt, onAnswer = { answer -> model.respond(prompt, answer) })
                } else {
                    Composer(
                        draft = model.draft,
                        attachments = attachments,
                        services = attached,
                        phase = state.phase,
                        attach = attach,
                        onRemoveAttachment = model::removeAttachment,
                        onOpenService = { viewingService = it.domain },
                        onSend = {
                            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                            model.send(environment.skills.map { it.name }.toSet())
                        },
                        onStop = {
                            haptics.performHapticFeedback(HapticFeedbackType.ContextClick)
                            model.stop()
                        },
                        onVoice = if (platform.speechAvailable) platform::listen else null,
                        placeholder = stringResource(if (state.editing != null) R.string.composer_editing else R.string.composer_placeholder),
                    )
                }
            }
        }
        state.notice?.let { notice ->
            NoticeToast(notice.message, model::dismissNotice, Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 64.dp))
        }
    }

    steps?.let { item -> StepsSheet(item) { steps = null } }
    if (choosingModel) {
        ModelSheet(environment.providers, state.model, environment.loadProviders, onChoose = { chosen: ChatModel ->
            model.chooseModel(chosen)
            choosingModel = false
        }, onDismiss = { choosingModel = false }, thinking = model.capabilities.setModel, onSetUp = environment.onProvidersChanged?.let {
            {
                choosingModel = false
                settingUpProviders = true
            }
        })
    }
    environment.onProvidersChanged?.takeIf { settingUpProviders }?.let { changed ->
        ProvidersSheet(platform, changed) { settingUpProviders = false }
    }
    attached.firstOrNull { it.domain == viewingService }?.let { service ->
        ServiceSheet(service, onRemove = { model.toggleService(service.domain) }) { viewingService = null }
    }
    if (choosingServices) {
        ServicesSheet(environment.services, state.services, environment.loadServices, model::toggleService) { choosingServices = false }
    }
    if (confirmDelete) {
        ConfirmDialog(
            title = stringResource(R.string.delete_conversation_title),
            message = stringResource(R.string.delete_conversation_message),
            confirm = stringResource(R.string.delete),
            tag = "conversation.delete",
            onConfirm = model::delete,
            onDismiss = { confirmDelete = false },
        )
    }
    if (renaming) {
        TextDialog(stringResource(R.string.rename), state.title.orEmpty(), stringResource(R.string.save), "conversation.rename", model::rename) { renaming = false }
    }
}

@Composable
private fun Transcript(
    state: ChatState,
    actions: MessageActions,
    bottomPadding: Dp,
    onSteps: (TranscriptItem.Thinking) -> Unit,
    onFile: (FileRef) -> Unit,
    onResume: () -> Unit,
    onRetryFailed: (() -> Unit)?,
    onFollow: (FollowIntent) -> Unit,
    onCancelQueued: ((QueuedMessage) -> Unit)?,
    onParent: (String) -> Unit,
) {
    val items = state.items
    if (items.isEmpty() && state.queued.isEmpty() && !state.phase.isActive) {
        EmptyState(state.temporary)
        return
    }
    val leadingRows = if (state.parentId != null) 1 else 0
    val list = rememberLazyListState(initialFirstVisibleItemIndex = leadingRows + items.lastIndex.coerceAtLeast(0), initialFirstVisibleItemScrollOffset = Int.MAX_VALUE / 4)
    val scope = rememberCoroutineScope()
    val turnEnds = remember(items, state.phase) {
        items.indices.filter { index ->
            items[index] is TranscriptItem.AgentContent && when (val next = items.getOrNull(index + 1)) {
                null -> !state.phase.isActive
                is TranscriptItem.UserText, is TranscriptItem.UserSkill -> true
                else -> false
            }
        }.map { items[it].id }.toSet()
    }
    val liveId = items.lastOrNull()?.id?.takeIf { state.phase.isActive }
    val lastUserId = items.lastOrNull { it is TranscriptItem.UserText || it is TranscriptItem.UserSkill }?.id
    var seenUserId by remember { mutableStateOf(lastUserId.takeUnless { items.size <= 1 && state.phase.isActive }) }
    val pin = rememberTranscriptPin(list)
    LaunchedEffect(lastUserId) {
        if (lastUserId == null || lastUserId == seenUserId) return@LaunchedEffect
        seenUserId = lastUserId
        val index = items.indexOfFirst { it.id == lastUserId }
        if (index >= 0) pin.pin(lastUserId, leadingRows + index)
    }
    StickToEndEffect(list, pinned = pin.key != null && state.phase.isActive)
    val awayFromBottom by remember { derivedStateOf { list.canScrollForward } }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            state = list,
            modifier = Modifier.fillMaxSize().testTag("conversation.transcript"),
            contentPadding = PaddingValues(start = OxSpacing.lg, end = OxSpacing.lg, top = 112.dp, bottom = bottomPadding + OxSpacing.md),
            verticalArrangement = Arrangement.spacedBy(OxSpacing.transcript),
        ) {
            state.parentId?.let { parent ->
                item(key = "parent") { ParentLink(state.parentTitle, onClick = { onParent(parent) }) }
            }
            items(items, key = { it.id }) { item ->
                Box(Modifier.fillMaxWidth().widthIn(max = OxSpacing.readable).animateItem(fadeInSpec = rowFade, placementSpec = null, fadeOutSpec = null)) {
                    TranscriptRow(item, turnEnd = item.id in turnEnds, live = item.id == liveId, actions = actions, onSteps = onSteps, onFile = onFile)
                }
            }
            if (state.followIntents.isNotEmpty() && !state.phase.isActive) {
                item(key = "follow") { FollowIntents(state.followIntents, onFollow) }
            }
            state.turnEnding?.takeIf { !state.phase.isActive && state.queued.isEmpty() }?.let { ending ->
                item(key = "turn-ending") { TurnEndingCard(ending, onResume, onRetryFailed) }
            }
            items(state.queued, key = { "q-${it.id}" }) { queued -> QueuedBubble(queued, onCancelQueued) }
            if (pin.runway > 0) {
                item(key = RUNWAY) { Spacer(Modifier.fillMaxWidth().height(with(LocalDensity.current) { pin.runway.toDp() })) }
            }
        }
        AnimatedVisibility(
            visible = awayFromBottom,
            enter = fadeIn(spring(stiffness = Spring.StiffnessMedium)) + scaleIn(initialScale = 0.5f),
            exit = fadeOut(spring(stiffness = Spring.StiffnessMedium)) + scaleOut(targetScale = 0.5f),
            modifier = Modifier.align(Alignment.BottomEnd).padding(end = OxSpacing.xl, bottom = bottomPadding + OxSpacing.sm),
        ) {
            GlassCircleButton(Icons.Filled.KeyboardArrowDown, stringResource(R.string.scroll_to_bottom), "conversation.scrollToBottom", Modifier.size(38.dp)) {
                scope.launch { list.scrollToEnd(animated = true) }
            }
        }
    }
}

internal const val RUNWAY = "runway"

private val rowFade = spring<Float>(stiffness = Spring.StiffnessMediumLow)
