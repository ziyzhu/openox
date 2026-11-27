package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.features.services.ServiceAvatar
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.glass
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.ServiceRow
import ai.openox.ox.remote.SkillRow
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
internal fun EditingChip(onCancel: () -> Unit, modifier: Modifier) {
    Row(Modifier.fillMaxWidth().padding(horizontal = OxSpacing.lg), horizontalArrangement = Arrangement.Start) {
        Row(
            modifier = modifier.glass(CircleShape).clip(CircleShape).clickable(onClick = onCancel).padding(horizontal = OxSpacing.md, vertical = OxSpacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs),
        ) {
            Text(stringResource(R.string.editing_message), style = MaterialTheme.typography.labelLarge)
            Icon(Icons.Outlined.Close, stringResource(R.string.cancel), modifier = Modifier.size(16.dp), tint = LocalOxColors.current.secondary)
        }
    }
}

@Composable
internal fun SkillSuggestions(draft: String, skills: List<SkillRow>, onPick: (SkillRow) -> Unit) {
    val query = draft.takeIf { it.startsWith("/") && ' ' !in it }?.removePrefix("/") ?: return
    val matches = skills.filter { it.name.startsWith(query.lowercase()) }.take(6)
    if (matches.isEmpty()) return
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = OxSpacing.md).glass(RoundedCornerShape(24.dp)).clip(RoundedCornerShape(24.dp)).padding(vertical = OxSpacing.sm)
            .testTag("conversation.skillPicker"),
    ) {
        matches.forEach { skill ->
            Row(
                modifier = Modifier.fillMaxWidth().clickable { onPick(skill) }.padding(horizontal = OxSpacing.lg, vertical = OxSpacing.md).testTag("conversation.skill.${skill.name}"),
                horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
            ) {
                Text("/${skill.name}", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                Text(skill.description, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
internal fun ServiceSuggestions(draft: String, services: List<ServiceRow>, attached: List<String>, onLoad: () -> Unit, onPick: (ServiceRow, String) -> Unit) {
    val start = draft.lastIndexOf('@').takeIf { it >= 0 && (it == 0 || draft[it - 1].isWhitespace()) } ?: return
    val query = draft.substring(start + 1).takeIf { token -> token.none { it.isWhitespace() } }?.lowercase() ?: return
    LaunchedEffect(Unit) { if (services.isEmpty()) onLoad() }
    val matches = services.filter { it.domain !in attached && (it.title.lowercase().contains(query) || it.domain.contains(query)) }.take(6)
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = OxSpacing.md).glass(RoundedCornerShape(24.dp)).clip(RoundedCornerShape(24.dp)).testTag("conversation.servicePicker"),
    ) {
        if (matches.isEmpty()) {
            Text(
                stringResource(if (services.isEmpty()) R.string.services_loading else R.string.services_none_found),
                style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary,
                modifier = Modifier.padding(horizontal = OxSpacing.lg, vertical = OxSpacing.md),
            )
        }
        matches.forEach { service ->
            Row(
                modifier = Modifier.fillMaxWidth().clickable { onPick(service, draft.substring(0, start)) }.padding(horizontal = OxSpacing.lg, vertical = OxSpacing.sm)
                    .testTag("conversation.servicePicker.${service.domain}"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(OxSpacing.md),
            ) {
                ServiceAvatar(service.title, service.favicon, 28.dp)
                Text(service.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
