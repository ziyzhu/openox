package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource

@Composable
internal fun ResolvedPrompt(item: TranscriptItem.Prompt) {
    Outlined(Modifier.fillMaxWidth().testTag("conversation.prompt.${item.id}")) {
        Column(Modifier.padding(OxSpacing.lg), verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
            Text(item.prompt, style = MaterialTheme.typography.titleMedium)
            val answer = item.answer ?: item.resolution
            if (answer != null) {
                Text(stringResource(R.string.prompt_answered, answer), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            }
        }
    }
}
