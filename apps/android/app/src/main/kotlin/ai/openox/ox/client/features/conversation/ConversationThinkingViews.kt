package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.OxSheet
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
fun StepsSheet(item: TranscriptItem.Thinking, onDismiss: () -> Unit) {
    OxSheet(onDismiss, stringResource(R.string.steps), "conversation.steps") {
        Column(Modifier.verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = OxSpacing.xl)) {
            StepsList(item.steps)
        }
    }
}

@Composable
internal fun ThinkingLine(item: TranscriptItem.Thinking, onSteps: (TranscriptItem.Thinking) -> Unit) {
    val pulse = if (item.completed) null else {
        rememberInfiniteTransition(label = "thinking").animateFloat(1f, 0.45f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha")
    }
    Row(
        modifier = Modifier
            .clickable(enabled = item.steps.isNotEmpty()) { onSteps(item) }
            .padding(vertical = OxSpacing.xs)
            .graphicsLayer { alpha = pulse?.value ?: 1f }
            .testTag("conversation.thinking.${item.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            thinkingLabel(item),
            style = MaterialTheme.typography.bodyLarge,
            color = LocalOxColors.current.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (item.steps.isNotEmpty()) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = LocalOxColors.current.muted, modifier = Modifier.size(22.dp))
        }
    }
}

@Composable
private fun thinkingLabel(item: TranscriptItem.Thinking): String {
    val last = item.steps.lastOrNull()
    val preview = when (last) {
        is ThinkingStep.Invocation -> last.purpose.ifBlank { last.name }
        is ThinkingStep.Reasoning -> last.text.lineSequence().firstOrNull { it.isNotBlank() }?.trim()
        null -> null
    }
    val seconds = item.seconds ?: return preview ?: stringResource(R.string.thinking_running)
    if (last is ThinkingStep.Invocation && preview != null) return preview
    return if (seconds < 60) pluralStringResource(R.plurals.thought_for, seconds, seconds)
    else pluralStringResource(R.plurals.thought_for_minutes, seconds % 60, seconds / 60, seconds % 60)
}

@Composable
fun StepsList(steps: List<ThinkingStep>) {
    val colors = LocalOxColors.current
    Column(Modifier.fillMaxWidth().padding(horizontal = OxSpacing.xl)) {
        steps.forEachIndexed { index, step ->
            Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.lg)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(top = 8.dp)) {
                    Box(Modifier.size(8.dp).background(colors.muted.copy(alpha = 0.7f), RoundedCornerShape(50)))
                    if (index < steps.lastIndex) Box(Modifier.size(width = 1.5.dp, height = 28.dp).background(colors.muted.copy(alpha = 0.35f)))
                }
                Column(Modifier.weight(1f).padding(bottom = OxSpacing.md), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    when (step) {
                        is ThinkingStep.Reasoning -> Text(step.text, style = MaterialTheme.typography.bodyLarge, color = colors.secondary)
                        is ThinkingStep.Invocation -> {
                            Text(step.purpose.ifBlank { step.name }, style = MaterialTheme.typography.bodyLarge)
                            val status = when (val outcome = step.outcome) {
                                InvocationOutcome.Running -> stringResource(R.string.invocation_running)
                                InvocationOutcome.Succeeded -> step.name
                                is InvocationOutcome.Failed -> stringResource(R.string.invocation_failed, outcome.message)
                            }
                            Text(
                                status,
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                color = if (step.outcome is InvocationOutcome.Failed) MaterialTheme.colorScheme.error else colors.muted,
                            )
                        }
                    }
                }
            }
        }
    }
}
