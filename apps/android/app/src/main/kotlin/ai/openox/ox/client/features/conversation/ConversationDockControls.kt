package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.glass
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.PendingPrompt
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun PromptDock(prompt: PendingPrompt, onAnswer: (String) -> Unit, modifier: Modifier = Modifier) {
    val custom = rememberSaveable(prompt.id, saver = TextFieldState.Saver) { TextFieldState() }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = OxSpacing.md, vertical = OxSpacing.sm)
            .glass(RoundedCornerShape(18.dp))
            .padding(OxSpacing.lg)
            .testTag("conversation.pendingPrompt"),
        verticalArrangement = Arrangement.spacedBy(OxSpacing.md),
    ) {
        Text(prompt.prompt, style = MaterialTheme.typography.titleMedium)
        if (prompt.requiresApp) {
            Text(stringResource(R.string.prompt_requires_app), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            return@Column
        }
        Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
            prompt.options.forEachIndexed { index, option ->
                ChipButton(
                    text = option,
                    tag = "conversation.prompt.option.$index",
                    style = if (index == 0) ChipStyle.Primary else ChipStyle.Secondary,
                    height = 44.dp,
                    fill = true,
                    modifier = Modifier.weight(1f),
                ) { onAnswer(option) }
            }
        }
        AnimatedVisibility(prompt.allowsCustomAnswer) {
            Row(
                modifier = Modifier.fillMaxWidth().background(LocalOxColors.current.chip, RoundedCornerShape(24.dp)).padding(start = OxSpacing.lg),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.weight(1f).padding(vertical = 12.dp)) {
                    if (custom.text.isEmpty()) Text(stringResource(R.string.prompt_custom_answer), color = LocalOxColors.current.muted, style = MaterialTheme.typography.bodyLarge)
                    BasicTextField(
                        state = custom,
                        lineLimits = TextFieldLineLimits.SingleLine,
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth().testTag("conversation.prompt.custom"),
                    )
                }
                RoundAction(Icons.Filled.ArrowUpward, stringResource(R.string.composer_send), "conversation.prompt.submit",
                    if (custom.text.isNotBlank()) LocalOxColors.current.composerSend else LocalOxColors.current.chip,
                    if (custom.text.isNotBlank()) { { onAnswer(custom.text.toString().trim()) } } else null)
            }
        }
    }
}
