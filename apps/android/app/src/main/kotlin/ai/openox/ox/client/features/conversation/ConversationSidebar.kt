package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.ConversationListState
import ai.openox.ox.client.HostState
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.ui.GlassCircleButton
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.glass
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.ConversationRow
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
fun CompletionBanner(row: ConversationRow?, onOpen: (ConversationRow) -> Unit, modifier: Modifier = Modifier) {
    AnimatedVisibility(
        visible = row != null,
        enter = fadeIn() + slideInVertically { -it },
        exit = fadeOut() + slideOutVertically { -it },
        modifier = modifier,
    ) {
        val current = row ?: return@AnimatedVisibility
        Column(
            modifier = Modifier
                .statusBarsPadding()
                .padding(horizontal = OxSpacing.lg, vertical = OxSpacing.sm)
                .fillMaxWidth()
                .glass(RoundedCornerShape(24.dp))
                .clip(RoundedCornerShape(24.dp))
                .clickable { onOpen(current) }
                .padding(horizontal = OxSpacing.lg, vertical = OxSpacing.md)
                .testTag("conversation.completionBanner"),
        ) {
            Text(stringResource(R.string.reply_ready), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(current.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

data class ConversationActions(
    val pin: ((ConversationRow) -> Unit)?,
    val rename: ((ConversationRow) -> Unit)?,
    val delete: ((ConversationRow) -> Unit)?,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SidebarScreen(
    host: HostState,
    list: ConversationListState,
    currentId: String?,
    actions: ConversationActions,
    onRefresh: () -> Unit,
    onOpen: (ConversationRow) -> Unit,
    onNew: () -> Unit,
    onSettings: () -> Unit,
) {
    val search = rememberTextFieldState()
    val query = search.text.toString()
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Text(
                stringResource(R.string.sidebar_title),
                style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                modifier = Modifier.padding(start = OxSpacing.lg + OxSpacing.xs, top = OxSpacing.lg, bottom = OxSpacing.xs).testTag("sidebar.title"),
            )
            when {
                host is HostState.Failed -> Message(host.message)
                list is ConversationListState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                list is ConversationListState.Failed -> Message(list.message)
                list is ConversationListState.Loaded -> {
                    val rows = remember(list.rows, query) {
                        val needle = query.trim().lowercase()
                        val matching = if (needle.isEmpty()) list.rows else list.rows.filter { it.title.lowercase().contains(needle) }
                        matching.sortedByDescending { it.pinned }
                    }
                    PullToRefreshBox(isRefreshing = false, onRefresh = onRefresh, modifier = Modifier.fillMaxSize().testTag("sidebar.list")) {
                        if (rows.isEmpty()) {
                            Message(stringResource(if (query.isBlank()) R.string.conversations_empty else R.string.search_empty))
                        } else {
                            val listState = rememberLazyListState()
                            LaunchedEffect(rows.firstOrNull()?.id) {
                                if (listState.firstVisibleItemIndex <= 1) listState.scrollToItem(0)
                            }
                            LazyColumn(state = listState, contentPadding = PaddingValues(top = OxSpacing.sm, bottom = 120.dp)) {
                                items(rows, key = { it.id }) { row ->
                                    SidebarRow(row, selected = row.id == currentId, actions = actions, onClick = { onOpen(row) })
                                }
                            }
                        }
                    }
                }
            }
        }
        SidebarBar(
            search = search,
            onSettings = onSettings,
            onNew = onNew,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun Message(text: String) {
    Box(Modifier.fillMaxSize().padding(OxSpacing.xl), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.muted)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SidebarRow(row: ConversationRow, selected: Boolean, actions: ConversationActions, onClick: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val hasMenu = actions.pin != null || actions.rename != null || actions.delete != null
    val status = rowStatus(row)
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OxSpacing.md, vertical = 2.dp)
                .clip(RoundedCornerShape(OxSpacing.md))
                .background(if (selected) MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f) else MaterialTheme.colorScheme.surface)
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = if (hasMenu) {
                        {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            menu = true
                        }
                    } else null,
                )
                .semantics { stateDescription = status }
                .padding(horizontal = OxSpacing.sm, vertical = 9.dp)
                .testTag("sidebar.row.${row.id}"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(row.title.ifBlank { stringResource(R.string.conversation_untitled) }, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(relativeTime(row.lastActivity ?: row.createdAt), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm), verticalAlignment = Alignment.CenterVertically) {
                if (row.pinned) Icon(Icons.Filled.PushPin, contentDescription = null, tint = LocalOxColors.current.muted, modifier = Modifier.size(16.dp))
                when {
                    row.running -> CircularProgressIndicator(Modifier.size(14.dp).testTag("sidebar.running.${row.id}"), strokeWidth = 1.5.dp, color = LocalOxColors.current.secondary)
                    row.awaiting != null -> Text(
                        stringResource(awaitingLabel(row.awaiting)),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f), CircleShape).padding(horizontal = 8.dp, vertical = 3.dp)
                            .testTag("sidebar.awaiting.${row.id}").clearAndSetSemantics {},
                    )
                    row.stopped -> Text(
                        stringResource(R.string.stopped),
                        style = MaterialTheme.typography.labelMedium,
                        color = LocalOxColors.current.secondary,
                        modifier = Modifier.testTag("sidebar.stopped.${row.id}").clearAndSetSemantics {},
                    )
                    row.unread -> Box(Modifier.size(8.dp).background(MaterialTheme.colorScheme.primary, CircleShape).testTag("sidebar.unread.${row.id}"))
                }
                if (row.scheduled) Icon(Icons.Filled.Schedule, contentDescription = null, tint = LocalOxColors.current.secondary, modifier = Modifier.size(20.dp))
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = MaterialTheme.shapes.large, modifier = Modifier.automation()) {
            actions.pin?.let { pin ->
                DropdownMenuItem(
                    text = { Text(stringResource(if (row.pinned) R.string.unpin else R.string.pin)) },
                    leadingIcon = { Icon(Icons.Outlined.PushPin, contentDescription = null) },
                    onClick = { menu = false; pin(row) },
                    modifier = Modifier.testTag("sidebar.favoriteRow.${row.id}"),
                )
            }
            actions.rename?.let { rename ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.rename)) },
                    leadingIcon = { Icon(Icons.Outlined.DriveFileRenameOutline, contentDescription = null) },
                    onClick = { menu = false; rename(row) },
                    modifier = Modifier.testTag("sidebar.renameRow.${row.id}"),
                )
            }
            actions.delete?.let { delete ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) },
                    leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { menu = false; delete(row) },
                    modifier = Modifier.testTag("sidebar.deleteRow.${row.id}"),
                )
            }
        }
    }
}

@Composable
private fun SidebarBar(search: TextFieldState, onSettings: () -> Unit, onNew: () -> Unit, modifier: Modifier) {
    val surface = MaterialTheme.colorScheme.surface
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(0f to surface.copy(alpha = 0f), 0.4f to surface.copy(alpha = 0.92f), 1f to surface))
            .navigationBarsPadding()
            .padding(horizontal = OxSpacing.lg, vertical = OxSpacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OxSpacing.md),
    ) {
        Row(
            modifier = Modifier.weight(1f).height(OxSpacing.touch + 4.dp).glass(CircleShape).padding(horizontal = OxSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Search, contentDescription = null, tint = LocalOxColors.current.muted, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(OxSpacing.sm))
            Box(Modifier.weight(1f)) {
                if (search.text.isEmpty()) Text(stringResource(R.string.search_conversations), color = LocalOxColors.current.muted, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
                BasicTextField(
                    state = search,
                    lineLimits = TextFieldLineLimits.SingleLine,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth().testTag("sidebar.search"),
                )
            }
            if (search.text.isNotEmpty()) {
                IconButton(onClick = { search.clearText() }, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.clear), tint = LocalOxColors.current.muted, modifier = Modifier.size(18.dp))
                }
            }
        }
        GlassCircleButton(Icons.Filled.Settings, stringResource(R.string.settings), "sidebar.settings", Modifier.size(OxSpacing.touch + 4.dp), onClick = onSettings)
        GlassCircleButton(Icons.Filled.EditNote, stringResource(R.string.conversations_new), "sidebar.newConversation", Modifier.size(OxSpacing.touch + 4.dp), onClick = onNew)
    }
}

private fun awaitingLabel(action: String?): Int = when (action) {
    "approval" -> R.string.awaiting_approval
    "login" -> R.string.awaiting_login
    "verification" -> R.string.awaiting_verification
    "payment" -> R.string.awaiting_payment
    else -> R.string.awaiting_reply
}

private fun awaitingStatus(action: String?): Int = when (action) {
    "approval" -> R.string.status_awaiting_approval
    "login" -> R.string.status_awaiting_login
    "verification" -> R.string.status_awaiting_verification
    "payment" -> R.string.status_awaiting_payment
    else -> R.string.status_awaiting_reply
}

@Composable
private fun rowStatus(row: ConversationRow): String = listOfNotNull(
    if (row.pinned) R.string.status_pinned else null,
    if (row.scheduled) R.string.status_scheduled else null,
    when {
        row.running -> R.string.status_plowing
        row.awaiting != null -> awaitingStatus(row.awaiting)
        row.stopped -> R.string.stopped
        row.unread -> R.string.status_unread
        else -> null
    },
).map { stringResource(it) }.joinToString(", ")

private val timeFormat: DateTimeFormatter = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)

private val dateFormat: DateTimeFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)

fun relativeTime(iso: String): String {
    val instant = runCatching { Instant.parse(iso) }.getOrNull() ?: return iso.take(10)
    val zone = ZoneId.systemDefault()
    val local = instant.atZone(zone)
    return if (local.toLocalDate() == LocalDate.now(zone)) timeFormat.format(local) else dateFormat.format(local)
}
