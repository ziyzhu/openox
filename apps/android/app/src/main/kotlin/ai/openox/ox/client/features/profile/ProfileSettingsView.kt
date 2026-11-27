package ai.openox.ox.client.features.profile

import ai.openox.ox.R
import ai.openox.ox.client.features.settings.Loadable
import ai.openox.ox.client.features.settings.SettingsPage
import ai.openox.ox.client.features.settings.SettingsViewModel
import ai.openox.ox.client.features.settings.locationLabel
import ai.openox.ox.client.ui.LoadingRow
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.client.ui.TextDialog
import ai.openox.ox.runtime.services.string
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun ProfilePage(model: SettingsViewModel, onOpen: (SettingsPage) -> Unit, onBack: () -> Unit) {
    val state by model.profile.collectAsStateWithLifecycle()
    val profile = (state as? Loadable.Loaded)?.value
    var renaming by remember { mutableStateOf(false) }
    LaunchedEffect(model) { model.loadProfile() }
    SettingsScaffold(profile?.name ?: stringResource(R.string.profile), "settings.profileDetail", onBack = onBack) {
        if (profile == null) {
            LoadingRow()
            return@SettingsScaffold
        }
        SettingsGroup(null) {
            SettingsRow(Icons.Outlined.DriveFileRenameOutline, stringResource(R.string.name), value = profile.name, tag = "settings.profileRename",
                onClick = if (model.supports("profile.update")) ({ renaming = true }) else null)
            SettingsRow(Icons.Outlined.Folder, stringResource(R.string.location), value = locationLabel(profile), tag = "settings.profileLocation", chevron = false, onClick = null)
        }
        SettingsGroup(null) {
            SettingsRow(Icons.Outlined.FolderOpen, stringResource(R.string.files), tag = "settings.files") { onOpen(SettingsPage.Files) }
            if (model.supports("skills.list")) SettingsRow(Icons.Outlined.Lightbulb, stringResource(R.string.skills), tag = "settings.skills") { onOpen(SettingsPage.Skills) }
            SettingsRow(Icons.Outlined.Psychology, stringResource(R.string.memory), tag = "settings.memory") { onOpen(SettingsPage.Memory) }
        }
    }
    if (renaming && profile != null) {
        TextDialog(stringResource(R.string.rename), profile.name, stringResource(R.string.save), "settings.profileRename", { model.renameProfile(it) }) { renaming = false }
    }
}
