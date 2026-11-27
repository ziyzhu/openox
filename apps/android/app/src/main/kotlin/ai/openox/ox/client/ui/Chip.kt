package ai.openox.ox.client.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

enum class ChipStyle { Primary, Secondary }

@Composable
fun ChipButton(
    text: String,
    tag: String,
    modifier: Modifier = Modifier,
    style: ChipStyle = ChipStyle.Secondary,
    enabled: Boolean = true,
    height: Dp = 32.dp,
    fill: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = LocalOxColors.current
    val background = when (style) {
        ChipStyle.Primary -> MaterialTheme.colorScheme.primary
        ChipStyle.Secondary -> colors.chip
    }
    val foreground = when (style) {
        ChipStyle.Primary -> MaterialTheme.colorScheme.onPrimary
        ChipStyle.Secondary -> MaterialTheme.colorScheme.onSurface
    }
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = OxSpacing.touch)
            .pressable(onClick, enabled)
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .then(if (fill) Modifier.fillMaxWidth() else Modifier)
                .height(height)
                .background(background.copy(alpha = if (enabled) 1f else 0.5f), RoundedCornerShape(50))
                .padding(horizontal = OxSpacing.md),
            contentAlignment = Alignment.Center,
        ) {
            Text(text, style = MaterialTheme.typography.labelLarge, color = foreground, maxLines = 1)
        }
    }
}
