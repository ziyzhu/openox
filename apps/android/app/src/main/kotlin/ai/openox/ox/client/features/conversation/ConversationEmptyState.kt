package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.app.OxMark
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
internal fun EmptyState(temporary: Boolean) {
    Column(
        Modifier.fillMaxSize().padding(OxSpacing.xl).testTag(if (temporary) "conversation.temporaryEmpty" else "conversation.persistedEmpty"),
        verticalArrangement = Arrangement.spacedBy(OxSpacing.md, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (temporary) {
            Text(stringResource(R.string.temporary_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.temporary_detail), style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary, textAlign = TextAlign.Center)
        } else {
            OxMark(Modifier.size(56.dp), color = MaterialTheme.colorScheme.primary.copy(alpha = 0.16f), faint = MaterialTheme.colorScheme.primary.copy(alpha = 0.07f))
        }
    }
}
