package ai.openox.ox.client.features.files

import ai.openox.ox.client.features.conversation.FileRef
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AttachFile
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
import androidx.compose.ui.unit.dp

@Composable
internal fun AttachmentChip(file: FileRef, onFile: (FileRef) -> Unit) {
    Row(
        modifier = Modifier
            .widthIn(max = 280.dp)
            .border(1.dp, LocalOxColors.current.outline, RoundedCornerShape(18.dp))
            .clip(RoundedCornerShape(18.dp))
            .clickable { onFile(file) }
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .testTag("conversation.message.file.${file.name}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
    ) {
        Icon(Icons.Outlined.AttachFile, contentDescription = null, modifier = Modifier.size(16.dp), tint = LocalOxColors.current.secondary)
        Text(file.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
    }
}
