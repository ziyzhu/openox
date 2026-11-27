package ai.openox.ox.client.ui

import ai.openox.ox.R
import ai.openox.ox.client.automation.automation
import ai.openox.ox.runtime.services.string
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OxSheet(onDismiss: () -> Unit, title: String, tag: String, content: @Composable () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 32.dp, topEnd = 32.dp),
        modifier = Modifier.automation().testTag(tag),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(bottom = OxSpacing.lg),
        )
        content()
    }
}

@Composable
fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = LocalOxColors.current.secondary,
        modifier = Modifier.padding(start = OxSpacing.xl, end = OxSpacing.xl, top = OxSpacing.lg, bottom = OxSpacing.xs),
    )
}

@Composable
fun ConfirmDialog(title: String, message: String, confirm: String, tag: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }, modifier = Modifier.testTag("$tag.confirm")) {
                Text(confirm, color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = MaterialTheme.colorScheme.surface,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.automation().testTag(tag),
    )
}

@Composable
fun TextDialog(
    title: String,
    initial: String,
    confirm: String,
    tag: String,
    onConfirm: (String) -> Unit,
    secret: Boolean = false,
    help: (@Composable () -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var value by rememberSaveable { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                if (secret) {
                    val hidden = rememberTextFieldState(initial)
                    LaunchedEffect(hidden) { snapshotFlow { hidden.text.toString() }.collect { value = it } }
                    OutlinedSecureTextField(state = hidden, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth().testTag("$tag.field"))
                } else {
                    OutlinedTextField(
                        value = value,
                        onValueChange = { value = it },
                        singleLine = true,
                        shape = MaterialTheme.shapes.medium,
                        modifier = Modifier.fillMaxWidth().testTag("$tag.field"),
                    )
                }
                help?.invoke()
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onDismiss(); onConfirm(value.trim()) },
                enabled = value.isNotBlank(),
                modifier = Modifier.testTag("$tag.confirm"),
            ) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = MaterialTheme.colorScheme.surface,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.automation().testTag(tag),
    )
}

private val pressSpring = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMedium)

@Composable
fun Modifier.glass(shape: Shape): Modifier {
    val colors = LocalOxColors.current
    return this
        .shadow(18.dp, shape, ambientColor = Color.Black.copy(alpha = 0.10f), spotColor = Color.Black.copy(alpha = 0.10f))
        .background(colors.glass, shape)
        .border(0.5.dp, colors.outline, shape)
}

@Composable
internal fun Modifier.pressable(onClick: () -> Unit, enabled: Boolean, role: Role = Role.Button): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.94f else 1f, pressSpring, label = "press")
    return this
        .scale(scale)
        .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = role, onClick = onClick)
}

@Composable
fun GlassCircleButton(
    icon: ImageVector,
    contentDescription: String,
    tag: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier
            .size(OxSpacing.touch)
            .glass(CircleShape)
            .clip(CircleShape)
            .pressable(onClick, enabled)
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(22.dp))
    }
}

@Composable
fun GlassCircle(contentDescription: String, tag: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .size(OxSpacing.touch)
            .glass(CircleShape)
            .clip(CircleShape)
            .pressable(onClick, true)
            .semantics { this.contentDescription = contentDescription }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
fun GlassPill(tag: String, modifier: Modifier = Modifier, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = modifier
            .height(OxSpacing.touch)
            .glass(CircleShape)
            .clip(CircleShape)
            .pressable(onClick, true)
            .padding(horizontal = OxSpacing.lg)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs),
        content = content,
    )
}

@Composable
fun Outlined(modifier: Modifier = Modifier, shape: Shape = MaterialTheme.shapes.large, content: @Composable () -> Unit) {
    Box(modifier.border(1.dp, LocalOxColors.current.outline.copy(alpha = 0.6f), shape).clip(shape)) { content() }
}
