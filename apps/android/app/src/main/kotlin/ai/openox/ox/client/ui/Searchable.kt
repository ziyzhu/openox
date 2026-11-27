package ai.openox.ox.client.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Composable
fun SearchField(
    state: TextFieldState,
    placeholder: String,
    tag: String,
    inset: Dp = OxSpacing.lg,
    fill: Color = LocalOxColors.current.chip,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = inset)
            .height(OxSpacing.touch)
            .background(fill, CircleShape)
            .padding(horizontal = OxSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = LocalOxColors.current.muted, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(OxSpacing.sm))
        Box(Modifier.weight(1f)) {
            if (state.text.isEmpty()) Text(placeholder, color = LocalOxColors.current.muted, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
            BasicTextField(
                state = state,
                lineLimits = TextFieldLineLimits.SingleLine,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                modifier = Modifier.fillMaxWidth().testTag(tag),
            )
        }
    }
}
