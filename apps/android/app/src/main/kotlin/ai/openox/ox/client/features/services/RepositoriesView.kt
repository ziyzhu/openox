package ai.openox.ox.client.features.services

import ai.openox.ox.R
import ai.openox.ox.client.features.settings.Loadable
import ai.openox.ox.client.features.settings.SettingsViewModel
import ai.openox.ox.client.ui.LoadingRow
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.runtime.services.string
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun RepositoriesPage(model: SettingsViewModel, onBack: () -> Unit) {
    val repositories by model.repositories.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.loadRepositories() }
    SettingsScaffold(stringResource(R.string.repositories), "settings.repositoriesPage", onBack = onBack) {
        SettingsGroup(null) {
            when (val state = repositories) {
                Loadable.Loading -> LoadingRow()
                is Loadable.Failed -> MessageRow(state.message)
                is Loadable.Loaded -> state.value.forEach { repository ->
                    SettingsRow(null, repository.name, subtitle = listOfNotNull(repository.provenance, repository.state, repository.error).joinToString(" · "),
                        value = stringResource(if (repository.enabled) R.string.enabled else R.string.disabled), tag = "settings.repository.${repository.id}",
                        chevron = false, onClick = null)
                }
            }
        }
    }
}
