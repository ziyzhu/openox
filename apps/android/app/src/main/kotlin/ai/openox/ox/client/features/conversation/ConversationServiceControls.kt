package ai.openox.ox.client.features.conversation

import ai.openox.ox.R
import ai.openox.ox.client.features.services.ServiceAvatar
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSheet
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.SearchField
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.ServiceRow
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
fun ServicesSheet(services: List<ServiceRow>, attached: List<String>, onLoad: () -> Unit, onToggle: (String) -> Unit, onDismiss: () -> Unit) {
    val search = rememberTextFieldState()
    val query = search.text.toString()
    LaunchedEffect(Unit) { onLoad() }
    OxSheet(onDismiss, stringResource(R.string.attach_services), "conversation.attach.servicesSheet") {
        SearchField(search, stringResource(R.string.search_services), "conversation.attach.search")
        val needle = query.trim().lowercase()
        val rows = services.filter { needle.isEmpty() || it.title.lowercase().contains(needle) || it.domain.contains(needle) }
        if (rows.isEmpty()) {
            Text(
                stringResource(R.string.services_empty),
                color = LocalOxColors.current.muted,
                modifier = Modifier.fillMaxWidth().padding(OxSpacing.xl),
                textAlign = TextAlign.Center,
            )
        }
        LazyColumn(contentPadding = PaddingValues(bottom = OxSpacing.xxl), modifier = Modifier.navigationBarsPadding()) {
            items(rows, key = { it.domain }) { service ->
                val on = service.domain in attached
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onToggle(service.domain) }
                        .padding(horizontal = OxSpacing.xl, vertical = 12.dp)
                        .testTag("conversation.attach.service.${service.domain}"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(OxSpacing.md),
                ) {
                    ServiceAvatar(service.title, service.favicon)
                    Column(Modifier.weight(1f)) {
                        Text(service.title, style = MaterialTheme.typography.bodyLarge)
                        Text(service.domain, style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
                    }
                    Icon(
                        if (on) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                        contentDescription = null,
                        tint = if (on) MaterialTheme.colorScheme.primary else LocalOxColors.current.muted,
                    )
                }
            }
        }
    }
}

@Composable
fun ServiceSheet(service: ServiceRow, onRemove: () -> Unit, onDismiss: () -> Unit) {
    OxSheet(onDismiss, service.title, "conversation.serviceSheet") {
        Column(
            modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = OxSpacing.xl).padding(bottom = OxSpacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(OxSpacing.md),
        ) {
            ServiceAvatar(service.title, service.favicon, 56.dp)
            Text(service.domain, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary)
            Text(stringResource(R.string.service_attached_detail), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.muted, textAlign = TextAlign.Center)
            TextButton(
                onClick = {
                    onDismiss()
                    onRemove()
                },
                modifier = Modifier.testTag("conversation.service.remove"),
            ) { Text(stringResource(R.string.service_remove), color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
internal fun ServiceChip(service: ServiceRow, onOpen: () -> Unit) {
    Row(
        modifier = Modifier
            .heightIn(min = 32.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(LocalOxColors.current.chip)
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(start = OxSpacing.xs, end = OxSpacing.md)
            .testTag("conversation.service.${service.domain}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OxSpacing.xs),
    ) {
        ServiceAvatar(service.title, service.favicon, 24.dp)
        Text(service.title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 160.dp))
    }
}
