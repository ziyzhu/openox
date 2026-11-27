package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
internal fun ParentLink(title: String?, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Row(
            modifier = Modifier.clip(CircleShape).clickable(onClick = onClick).padding(horizontal = OxSpacing.md, vertical = OxSpacing.sm).testTag("conversation.children.parent"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs),
        ) {
            Icon(Icons.AutoMirrored.Filled.Undo, null, tint = LocalOxColors.current.secondary, modifier = Modifier.size(16.dp))
            Text(stringResource(R.string.from_parent, title ?: stringResource(R.string.conversation_untitled)), style = MaterialTheme.typography.bodyMedium,
                color = LocalOxColors.current.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 240.dp))
        }
    }
}
