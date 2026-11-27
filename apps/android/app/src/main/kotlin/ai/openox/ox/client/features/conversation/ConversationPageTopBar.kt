package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.ui.GlassCircle
import ai.openox.ox.client.ui.GlassCircleButton
import ai.openox.ox.client.ui.GlassPill
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Share
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun Header(
    state: ChatState,
    canChangeModel: Boolean,
    canRename: Boolean,
    canDelete: Boolean,
    onSidebar: () -> Unit,
    onModel: () -> Unit,
    onTemporary: () -> Unit,
    onCopy: () -> Unit,
    onExport: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    val surface = LocalOxColors.current.conversationSurface
    Box(Modifier.fillMaxWidth().background(Brush.verticalGradient(0f to surface, 0.7f to surface.copy(alpha = 0.92f), 1f to surface.copy(alpha = 0f)))) {
        Row(
            modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = OxSpacing.lg).padding(top = OxSpacing.sm, bottom = OxSpacing.lg),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
        ) {
            GlassCircle(stringResource(R.string.open_sidebar), "conversation.openSidebar", onSidebar) { SidebarGlyph() }
            if ((state.isDraft && state.conversationId == null) || (canChangeModel && state.conversationId != null && !state.phase.isActive)) {
                GlassPill("conversation.modelPicker", onClick = onModel) {
                    Text(state.model?.name ?: stringResource(R.string.model_default), style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 180.dp))
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = LocalOxColors.current.muted, modifier = Modifier.size(18.dp))
                }
            }
            Spacer(Modifier.weight(1f))
            if (state.conversationId == null) {
                GlassCircle(stringResource(R.string.temporary_toggle), "conversation.temporaryToggle", onTemporary) { TemporaryGlyph(state.temporary) }
            } else {
                MoreMenu(canRename, canDelete, onCopy, onExport, onRename, onDelete)
            }
        }
    }
}

@Composable
private fun MoreMenu(canRename: Boolean, canDelete: Boolean, onCopy: () -> Unit, onExport: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        GlassCircleButton(Icons.Filled.MoreHoriz, stringResource(R.string.more), "conversation.more") { open = true }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, shape = MaterialTheme.shapes.extraLarge, modifier = Modifier.automation()) {
            DropdownMenuItem(text = { Text(stringResource(R.string.copy)) }, leadingIcon = { Icon(Icons.Outlined.ContentCopy, null) },
                onClick = { open = false; onCopy() }, modifier = Modifier.testTag("conversation.copy"))
            DropdownMenuItem(text = { Text(stringResource(R.string.export)) }, leadingIcon = { Icon(Icons.Outlined.Share, null) },
                onClick = { open = false; onExport() }, modifier = Modifier.testTag("conversation.export"))
            if (canRename) DropdownMenuItem(text = { Text(stringResource(R.string.rename)) }, leadingIcon = { Icon(Icons.Outlined.DriveFileRenameOutline, null) },
                onClick = { open = false; onRename() }, modifier = Modifier.testTag("conversation.rename"))
            if (canDelete) {
                HorizontalDivider()
                DropdownMenuItem(text = { Text(stringResource(R.string.delete), color = MaterialTheme.colorScheme.error) },
                    leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = MaterialTheme.colorScheme.error) },
                    onClick = { open = false; onDelete() }, modifier = Modifier.testTag("conversation.delete"))
            }
        }
    }
}

@Composable
private fun SidebarGlyph() {
    val color = MaterialTheme.colorScheme.onSurface
    Canvas(Modifier.size(width = 20.dp, height = 12.dp)) {
        val stroke = 2.5.dp.toPx()
        drawLine(color, Offset(stroke / 2, stroke / 2), Offset(size.width - stroke / 2, stroke / 2), stroke, StrokeCap.Round)
        drawLine(color, Offset(stroke / 2, size.height - stroke / 2), Offset(size.width * 0.62f, size.height - stroke / 2), stroke, StrokeCap.Round)
    }
}

@Composable
private fun TemporaryGlyph(on: Boolean) {
    val color = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
    Canvas(Modifier.size(22.dp)) {
        drawCircle(
            color = color,
            radius = size.minDimension / 2 - 1.dp.toPx(),
            style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 3.5.dp.toPx()))),
        )
        if (on) drawCircle(color = color, radius = size.minDimension / 5)
    }
}
