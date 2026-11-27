package ai.openox.ox.client.features.files

import ai.openox.ox.R
import ai.openox.ox.client.features.settings.Loadable
import ai.openox.ox.client.features.settings.SettingsViewModel
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ConfirmDialog
import ai.openox.ox.client.ui.LoadingRow
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.FolderGrantRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun FilesPage(model: SettingsViewModel, onBack: () -> Unit) {
    val folders by model.folders.collectAsStateWithLifecycle()
    var unmounting by remember { mutableStateOf<FolderGrantRow?>(null) }
    LaunchedEffect(model) { model.loadFolders() }
    SettingsScaffold(stringResource(R.string.files), "settings.filesPage", onBack = onBack) {
        Text(stringResource(R.string.files_guidance), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
        SettingsGroup(stringResource(R.string.folders)) {
            when (val state = folders) {
                Loadable.Loading -> LoadingRow()
                is Loadable.Failed -> MessageRow(state.message)
                is Loadable.Loaded -> if (state.value.isEmpty()) MessageRow(stringResource(R.string.folders_empty)) else state.value.forEach { folder ->
                    SettingsRow(Icons.Outlined.Folder, folder.name, tag = "profile.files.mount.${folder.id}", chevron = false,
                        trailing = { ChipButton(stringResource(R.string.unmount), "profile.files.remove.${folder.id}") { unmounting = folder } }, onClick = null)
                }
            }
        }
    }
    unmounting?.let { folder ->
        ConfirmDialog(stringResource(R.string.unmount_title, folder.name), stringResource(R.string.unmount_message), stringResource(R.string.unmount), "profile.files.confirmUnmount",
            onConfirm = { model.unmount(folder) }, onDismiss = { unmounting = null })
    }
}
