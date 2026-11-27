package ai.openox.ox.client.features.providers

import ai.openox.ox.R
import ai.openox.ox.client.ProvidersState
import ai.openox.ox.client.features.conversation.ChatModel
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.OxSheet
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.SearchField
import ai.openox.ox.client.ui.SectionHeader
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun ModelSheet(
    providers: ProvidersState,
    selected: ChatModel?,
    onLoad: () -> Unit,
    onChoose: (ChatModel) -> Unit,
    onDismiss: () -> Unit,
    title: String = stringResource(R.string.models),
    onSetUp: (() -> Unit)? = null,
    thinking: Boolean = false,
) {
    val search = rememberTextFieldState()
    val query = search.text.toString()
    LaunchedEffect(Unit) { onLoad() }
    OxSheet(onDismiss, title, "conversation.modelSelection") {
        SearchField(search, stringResource(R.string.search_models), "conversation.modelSearch")
        when (providers) {
            ProvidersState.Idle, ProvidersState.Loading -> Box(Modifier.fillMaxWidth().padding(OxSpacing.xl), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            is ProvidersState.Failed -> Text(providers.message, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(OxSpacing.xl))
            is ProvidersState.Loaded -> {
                val needle = query.trim().lowercase()
                val efforts = providers.providers.firstOrNull { it.id == selected?.providerId }?.models?.firstOrNull { it.id == selected?.modelId }?.reasoningEfforts.orEmpty()
                LazyColumn(contentPadding = PaddingValues(bottom = OxSpacing.xxl), modifier = Modifier.navigationBarsPadding()) {
                    if (thinking && selected != null && efforts.isNotEmpty()) item(key = "effort") {
                        SectionHeader(stringResource(R.string.thinking_level))
                        Row(
                            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = OxSpacing.xl, vertical = OxSpacing.xs),
                            horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
                        ) {
                            (listOf<String?>(null) + efforts).forEach { effort ->
                                ChipButton(
                                    text = effortLabel(effort),
                                    tag = "conversation.modelEffort.${effort ?: "default"}",
                                    style = if (selected.effort == effort) ChipStyle.Primary else ChipStyle.Secondary,
                                ) { onChoose(selected.copy(effort = effort)) }
                            }
                        }
                    }
                    if (onSetUp != null) item(key = "setup") {
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable(onClick = onSetUp).padding(horizontal = OxSpacing.xl, vertical = 14.dp).testTag("conversation.modelProviders"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(stringResource(R.string.providers), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                                Text(stringResource(R.string.providers_setup_detail), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = LocalOxColors.current.muted)
                        }
                    }
                    providers.providers.forEach { provider ->
                        val models = provider.models.filter { needle.isEmpty() || it.displayName.lowercase().contains(needle) || provider.displayName.lowercase().contains(needle) }
                        if (models.isNotEmpty()) {
                            item(key = "p-${provider.id}") { SectionHeader(provider.displayName) }
                            items(models, key = { "${provider.id}/${it.id}" }) { model ->
                                val chosen = selected?.providerId == provider.id && selected.modelId == model.id
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { onChoose(ChatModel(provider.id, model.id, model.displayName, selected?.effort?.takeIf { it in model.reasoningEfforts })) }
                                        .padding(horizontal = OxSpacing.xl, vertical = 14.dp)
                                        .testTag("conversation.modelOption.${provider.id}.${model.id}"),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(model.displayName, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                                    if (chosen) Icon(Icons.Filled.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun effortLabel(effort: String?): String = when (effort) {
    null -> stringResource(R.string.effort_default)
    "none" -> stringResource(R.string.effort_none)
    "minimal" -> stringResource(R.string.effort_minimal)
    "low" -> stringResource(R.string.effort_low)
    "medium" -> stringResource(R.string.effort_medium)
    "high" -> stringResource(R.string.effort_high)
    "xhigh" -> stringResource(R.string.effort_xhigh)
    "max" -> stringResource(R.string.effort_max)
    else -> effort
}
