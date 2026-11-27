package ai.openox.ox.client.features.skills

import ai.openox.ox.R
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.SearchField
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.SkillRow
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun SkillsPage(skills: List<SkillRow>, onLoad: () -> Unit, onBack: () -> Unit) {
    val search = rememberTextFieldState()
    val query = search.text.toString()
    LaunchedEffect(Unit) { onLoad() }
    SettingsScaffold(stringResource(R.string.skills), "settings.skillsPage", onBack = onBack) {
        SearchField(search, stringResource(R.string.search_skills), "settings.skills.search", inset = 0.dp, fill = MaterialTheme.colorScheme.surface)
        val rows = skills.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) || it.description.contains(query.trim(), ignoreCase = true) }
        SettingsGroup(null) {
            if (rows.isEmpty()) MessageRow(stringResource(R.string.skills_empty))
            rows.forEach { skill ->
                SettingsRow(Icons.Outlined.Lightbulb, "/${skill.name}", subtitle = skill.description, tag = "settings.skill.${skill.name}", chevron = false, onClick = null)
            }
        }
        Text(stringResource(R.string.skills_guidance), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
    }
}
