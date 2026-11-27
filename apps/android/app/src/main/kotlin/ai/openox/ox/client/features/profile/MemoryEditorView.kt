package ai.openox.ox.client.features.profile

import ai.openox.ox.R
import ai.openox.ox.android.Platform
import ai.openox.ox.client.features.settings.Loadable
import ai.openox.ox.client.features.settings.SettingsViewModel
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.GlassCircleButton
import ai.openox.ox.client.ui.LoadingRow
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun MemoryPage(model: SettingsViewModel, platform: Platform, onBack: () -> Unit) {
    val memory by model.memory.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.loadMemory() }
    DisposableEffect(model) { onDispose { model.saveMemory() } }
    LaunchedEffect(model) { model.messages.collect { if (it == "saved") platform.toast(platform.string(R.string.memory_saved)) else platform.toast(it) } }
    SettingsScaffold(
        stringResource(R.string.memory), "settings.memoryEditor", onBack = onBack, scroll = false,
        action = {
            val draft = (memory as? Loadable.Loaded)?.value
            Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                GlassCircleButton(Icons.Outlined.ContentCopy, stringResource(R.string.copy), "settings.memoryCopy") {
                    draft?.let { platform.copy(model.memoryText.text.toString()); platform.toast(platform.string(R.string.message_copied)) }
                }
                ChipButton(stringResource(R.string.save), "settings.memorySave", style = ChipStyle.Primary, enabled = draft != null && model.memoryText.text.toString() != draft.saved, onClick = model::saveMemory)
            }
        },
    ) {
        Text(stringResource(R.string.memory_guidance), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
        when (val state = memory) {
            Loadable.Loading -> LoadingRow()
            is Loadable.Failed -> MessageRow(state.message)
            is Loadable.Loaded -> Box(
                Modifier.fillMaxWidth().weight(1f).background(MaterialTheme.colorScheme.surface, RoundedCornerShape(24.dp)).padding(OxSpacing.lg),
            ) {
                BasicTextField(
                    state = model.memoryText,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxSize().testTag("settings.memoryText"),
                )
            }
        }
    }
}
