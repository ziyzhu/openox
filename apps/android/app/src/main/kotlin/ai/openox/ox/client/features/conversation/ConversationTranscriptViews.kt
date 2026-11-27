package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.features.files.AttachmentChip
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.FollowIntent
import ai.openox.ox.remote.QueuedMessage
import ai.openox.ox.remote.TurnEnding
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.CallSplit
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.SubdirectoryArrowRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
internal fun TurnEndingCard(ending: TurnEnding, onResume: () -> Unit, onRetry: (() -> Unit)?) {
    val stopped = ending.kind == "stopped"
    Outlined(Modifier.fillMaxWidth().testTag("conversation.turnEnding.${ending.kind}")) {
        Row(Modifier.padding(OxSpacing.lg), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(OxSpacing.md)) {
            Icon(if (stopped) Icons.Filled.Stop else Icons.Outlined.ErrorOutline, null,
                tint = if (stopped) LocalOxColors.current.secondary else MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(if (stopped) R.string.stopped else R.string.failed), style = MaterialTheme.typography.titleSmall)
                Text(if (stopped) stringResource(R.string.stopped_detail) else ending.message.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            }
            if (stopped) ChipButton(stringResource(R.string.resume), "conversation.resume", onClick = onResume)
            else onRetry?.let { ChipButton(stringResource(R.string.retry), "conversation.retryFailed", onClick = it) }
        }
    }
}

@Composable
internal fun FollowIntents(intents: List<FollowIntent>, onFollow: (FollowIntent) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        intents.forEachIndexed { index, intent ->
            if (index > 0) HorizontalDivider(color = LocalOxColors.current.outline)
            Row(
                modifier = Modifier.fillMaxWidth().clickable { onFollow(intent) }.padding(vertical = OxSpacing.md).testTag("conversation.followIntent.$index"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
            ) {
                Icon(Icons.Outlined.SubdirectoryArrowRight, null, tint = LocalOxColors.current.secondary, modifier = Modifier.size(18.dp))
                Text(intent.label, style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

@Composable
internal fun QueuedBubble(message: QueuedMessage, onCancel: ((QueuedMessage) -> Unit)?) {
    Column(Modifier.fillMaxWidth().alpha(0.55f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(OxSpacing.xs)) {
        Text(
            message.text,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.widthIn(max = 300.dp).background(LocalOxColors.current.bubble, RoundedCornerShape(22.dp)).padding(horizontal = 16.dp, vertical = 10.dp),
        )
        Row(
            modifier = Modifier.clip(CircleShape).clickable(enabled = onCancel != null) { onCancel?.invoke(message) }.padding(horizontal = OxSpacing.sm, vertical = 2.dp)
                .testTag("conversation.queued.${message.id}"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs),
        ) {
            Icon(Icons.Outlined.Schedule, null, modifier = Modifier.size(14.dp), tint = LocalOxColors.current.secondary)
            Text(stringResource(R.string.queued), style = MaterialTheme.typography.labelMedium, color = LocalOxColors.current.secondary)
            if (onCancel != null) Icon(Icons.Outlined.Close, stringResource(R.string.cancel), modifier = Modifier.size(14.dp), tint = LocalOxColors.current.secondary)
        }
    }
}

data class MessageActions(
    val copy: (String) -> Unit,
    val share: (String) -> Unit,
    val edit: ((TranscriptItem.UserText) -> Unit)?,
    val branch: ((TranscriptItem.AgentContent) -> Unit)?,
    val retry: ((TranscriptItem.AgentContent) -> Unit)?,
)

@Composable
fun TranscriptRow(
    item: TranscriptItem,
    turnEnd: Boolean,
    live: Boolean,
    actions: MessageActions,
    onSteps: (TranscriptItem.Thinking) -> Unit,
    onFile: (FileRef) -> Unit,
) {
    when (item) {
        is TranscriptItem.UserText -> UserBubble(item.id, item.text, item.attachments, actions, onFile, edit = actions.edit?.let { edit -> { edit(item) } })
        is TranscriptItem.UserSkill -> UserBubble(item.id, "/${item.skill} ${item.argument}".trim(), emptyList(), actions, onFile, edit = null)
        is TranscriptItem.AgentContent -> AgentContent(item, turnEnd, live, actions, onFile)
        is TranscriptItem.Thinking -> ThinkingLine(item, onSteps)
        is TranscriptItem.Prompt -> ResolvedPrompt(item)
        is TranscriptItem.Compaction -> Divided(stringResource(R.string.compaction))
        is TranscriptItem.Unsupported -> Divided(stringResource(R.string.unsupported_block, item.type))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun UserBubble(id: String, text: String, attachments: List<FileRef>, actions: MessageActions, onFile: (FileRef) -> Unit, edit: (() -> Unit)?) {
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(OxSpacing.xs)) {
            attachments.forEach { file -> AttachmentChip(file, onFile) }
            if (text.isNotEmpty()) {
                Box {
                    Text(
                        text,
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier
                            .widthIn(max = 300.dp)
                            .background(LocalOxColors.current.bubble, RoundedCornerShape(22.dp))
                            .combinedClickable(onClick = {}, onLongClick = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                menu = true
                            })
                            .padding(horizontal = 16.dp, vertical = 10.dp)
                            .testTag("conversation.message.user.$id"),
                    )
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = MaterialTheme.shapes.large, modifier = Modifier.automation()) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.copy)) },
                            leadingIcon = { Icon(Icons.Outlined.ContentCopy, contentDescription = null) },
                            onClick = { menu = false; actions.copy(text) },
                        )
                        edit?.let { action ->
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.edit)) },
                                leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                                onClick = { menu = false; action() },
                                modifier = Modifier.testTag("conversation.message.edit.$id"),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AgentContent(item: TranscriptItem.AgentContent, turnEnd: Boolean, live: Boolean, actions: MessageActions, onFile: (FileRef) -> Unit) {
    val text = remember(item.parts) { item.parts.filterIsInstance<AgentPart.Text>().joinToString("\n\n") { it.markdown.trim() } }
    Column(
        modifier = Modifier.fillMaxWidth().testTag("conversation.message.agent.${item.id}"),
        verticalArrangement = Arrangement.spacedBy(OxSpacing.sm),
    ) {
        item.parts.forEach { part ->
            when (part) {
                is AgentPart.Text -> {
                    val shown = rememberRevealedText(part.markdown.trimEnd(), live)
                    if (shown.isNotBlank()) OxMarkdown(shown)
                }
                is AgentPart.Progress -> Text(part.text, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary)
                is AgentPart.File -> AttachmentChip(part.file, onFile)
                is AgentPart.Widget -> Divided(stringResource(R.string.unsupported_block, part.kind))
            }
        }
        if (turnEnd && text.isNotBlank()) {
            Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs), modifier = Modifier.padding(top = OxSpacing.xs)) {
                ActionIcon(Icons.Outlined.ContentCopy, stringResource(R.string.copy), "conversation.message.copy.${item.id}") { actions.copy(text) }
                ActionIcon(Icons.Outlined.Share, stringResource(R.string.share), "conversation.message.share.${item.id}") { actions.share(text) }
                actions.branch?.let { branch -> ActionIcon(Icons.AutoMirrored.Outlined.CallSplit, stringResource(R.string.branch), "conversation.message.branch.${item.id}") { branch(item) } }
                actions.retry?.let { retry -> ActionIcon(Icons.Outlined.Refresh, stringResource(R.string.retry_reply), "conversation.message.retry.${item.id}") { retry(item) } }
            }
        }
    }
}

@Composable
private fun ActionIcon(icon: ImageVector, label: String, tag: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier.size(width = 32.dp, height = 36.dp).clickable(onClick = onClick).testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = LocalOxColors.current.secondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun Divided(text: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(OxSpacing.md)) {
        HorizontalDivider(Modifier.weight(1f), color = LocalOxColors.current.outline)
        Text(text, style = MaterialTheme.typography.labelMedium, color = LocalOxColors.current.muted)
        HorizontalDivider(Modifier.weight(1f), color = LocalOxColors.current.outline)
    }
}
