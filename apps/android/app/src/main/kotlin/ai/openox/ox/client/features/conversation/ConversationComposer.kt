package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.glass
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.ServiceRow
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

data class AttachOptions(
    val camera: (() -> Unit)?,
    val photos: (() -> Unit)?,
    val files: (() -> Unit)?,
    val services: (() -> Unit)?,
) {
    val any: Boolean get() = camera != null || photos != null || files != null || services != null
}

private val widthSpring = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow)

@Composable
fun Composer(
    draft: TextFieldState,
    attachments: List<Attachment>,
    services: List<ServiceRow>,
    phase: RunPhase,
    attach: AttachOptions,
    onRemoveAttachment: (Attachment) -> Unit,
    onOpenService: (ServiceRow) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onVoice: (() -> Unit)?,
    placeholder: String,
    modifier: Modifier = Modifier,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val focusManager = LocalFocusManager.current
    val keyboardShown = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    LaunchedEffect(keyboardShown) { if (!keyboardShown) focusManager.clearFocus() }
    val active = focused || draft.text.isNotEmpty() || attachments.isNotEmpty() || phase.isActive
    val fraction by animateFloatAsState(if (active) 1f else 0.84f, widthSpring, label = "composerWidth")
    val sendable = (draft.text.isNotBlank() || attachments.isNotEmpty()) && !phase.isActive
    BoxWithConstraints(modifier.fillMaxWidth().padding(horizontal = if (active) OxSpacing.md else OxSpacing.sm, vertical = OxSpacing.sm), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .width(maxWidth * fraction)
                .glass(RoundedCornerShape(24.dp))
                .clip(RoundedCornerShape(24.dp)),
        ) {
            if (attachments.isNotEmpty() || services.isNotEmpty()) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = OxSpacing.md, end = OxSpacing.md, top = OxSpacing.md),
                    horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
                ) {
                    services.forEach { service -> ServiceChip(service) { onOpenService(service) } }
                    attachments.forEach { file -> DraftChip(file.name, "conversation.attachment.${file.name}") { onRemoveAttachment(file) } }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = OxSpacing.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (attach.any) AttachButton(attach) else Box(Modifier.width(OxSpacing.md))
                Box(Modifier.weight(1f).padding(vertical = 14.dp), contentAlignment = Alignment.CenterStart) {
                    if (draft.text.isEmpty()) {
                        Text(placeholder, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    BasicTextField(
                        state = draft,
                        interactionSource = interaction,
                        lineLimits = TextFieldLineLimits.MultiLine(maxHeightInLines = 8),
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth().testTag("conversation.input"),
                    )
                }
                if (onVoice != null) {
                    Box(
                        modifier = Modifier.size(OxSpacing.touch).clip(CircleShape).clickable(role = Role.Button) { onVoice() }.testTag("conversation.speechHold"),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.Mic, contentDescription = stringResource(R.string.voice_input), tint = MaterialTheme.colorScheme.onSurface) }
                }
                AnimatedContent(
                    targetState = when {
                        phase == RunPhase.Sending || phase == RunPhase.Stopping -> ComposerAction.Busy
                        phase.isActive -> ComposerAction.Stop
                        sendable -> ComposerAction.Send
                        onVoice != null -> ComposerAction.None
                        else -> ComposerAction.SendDisabled
                    },
                    transitionSpec = { (fadeIn() + scaleIn(initialScale = 0.7f)) togetherWith (fadeOut() + scaleOut(targetScale = 0.7f)) },
                    label = "composerAction",
                ) { action ->
                    when (action) {
                        ComposerAction.Send -> RoundAction(Icons.Filled.ArrowUpward, stringResource(R.string.composer_send), "conversation.send", LocalOxColors.current.composerSend, onSend)
                        ComposerAction.SendDisabled -> RoundAction(Icons.Filled.ArrowUpward, stringResource(R.string.composer_send), "conversation.send", LocalOxColors.current.chip, null)
                        ComposerAction.Stop -> RoundAction(Icons.Filled.Stop, stringResource(R.string.composer_stop), "conversation.stop", LocalOxColors.current.composerSend, onStop)
                        ComposerAction.Busy -> Box(Modifier.size(OxSpacing.touch).testTag("conversation.busy"), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = LocalOxColors.current.composerSend)
                        }
                        ComposerAction.None -> Box(Modifier.width(OxSpacing.sm))
                    }
                }
            }
        }
    }
}

private enum class ComposerAction { Send, SendDisabled, Stop, Busy, None }

@Composable
internal fun RoundAction(icon: ImageVector, label: String, tag: String, color: Color, onClick: (() -> Unit)?) {
    Box(
        modifier = Modifier.size(OxSpacing.touch).clip(CircleShape).clickable(enabled = onClick != null, role = Role.Button) { onClick?.invoke() }.testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(34.dp).background(color, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = label, tint = if (onClick != null) Color.White else LocalOxColors.current.muted, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun AttachButton(attach: AttachOptions) {
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            modifier = Modifier.size(OxSpacing.touch).clip(CircleShape).clickable { open = true }.testTag("conversation.attach"),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.attach), tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(26.dp)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, shape = MaterialTheme.shapes.extraLarge, modifier = Modifier.automation().widthIn(min = 240.dp)) {
            attach.camera?.let { AttachItem(Icons.Outlined.CameraAlt, R.string.attach_camera, "conversation.attach.camera") { open = false; it() } }
            attach.photos?.let { AttachItem(Icons.Outlined.Image, R.string.attach_photos, "conversation.attach.photos") { open = false; it() } }
            attach.files?.let { AttachItem(Icons.Outlined.AttachFile, R.string.attach_files, "conversation.attach.files") { open = false; it() } }
            attach.services?.let { AttachItem(Icons.Outlined.GridView, R.string.attach_services, "conversation.attach.services") { open = false; it() } }
        }
    }
}

@Composable
private fun AttachItem(icon: ImageVector, label: Int, tag: String, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(stringResource(label), style = MaterialTheme.typography.bodyLarge) },
        leadingIcon = {
            Box(Modifier.size(40.dp).background(LocalOxColors.current.chip, CircleShape), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            }
        },
        onClick = onClick,
        modifier = Modifier.padding(vertical = 2.dp).testTag(tag),
    )
}

@Composable
private fun DraftChip(label: String, tag: String, onRemove: () -> Unit) {
    Row(
        modifier = Modifier.background(LocalOxColors.current.chip, RoundedCornerShape(24.dp)).padding(start = OxSpacing.md).testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(140.dp))
        Box(Modifier.size(32.dp).clip(CircleShape).clickable(onClick = onRemove), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.remove), modifier = Modifier.size(16.dp), tint = LocalOxColors.current.secondary)
        }
    }
}
