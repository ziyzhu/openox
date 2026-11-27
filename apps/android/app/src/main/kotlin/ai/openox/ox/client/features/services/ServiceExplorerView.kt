package ai.openox.ox.client.features.services

import ai.openox.ox.R
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.SearchField
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.runtime.services.string
import ai.openox.ox.remote.ServiceRow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun ServicesPage(services: List<ServiceRow>, onLoad: () -> Unit, onReload: (ServiceRow) -> Unit, onRefreshAuth: (ServiceRow) -> Unit, onBack: () -> Unit) {
    val search = rememberTextFieldState()
    val query = search.text.toString()
    LaunchedEffect(Unit) { onLoad() }
    SettingsScaffold(stringResource(R.string.services), "settings.servicesPage", onBack = onBack) {
        SearchField(search, stringResource(R.string.search_services), "conversation.attach.search", inset = 0.dp, fill = MaterialTheme.colorScheme.surface)
        val rows = services.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) || it.domain.contains(query.trim(), ignoreCase = true) }
        SettingsGroup(null) {
            if (rows.isEmpty()) MessageRow(stringResource(R.string.services_empty))
            rows.forEach { service -> ServiceSettingsRow(service, onReload, onRefreshAuth) }
        }
    }
}

@Composable
private fun ServiceSettingsRow(service: ServiceRow, onReload: (ServiceRow) -> Unit, onRefreshAuth: (ServiceRow) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        SettingsRow(null, service.title, subtitle = listOfNotNull(service.domain, signInLabel(service.signIn)).joinToString(" · "),
            tag = "settings.service.${service.domain}", leading = { ServiceAvatar(service.title, service.favicon) }, chevron = false) { menu = true }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, shape = MaterialTheme.shapes.large, modifier = Modifier.automation()) {
            DropdownMenuItem(text = { Text(stringResource(R.string.service_reload)) }, onClick = { menu = false; onReload(service) })
            DropdownMenuItem(text = { Text(stringResource(R.string.service_refresh_auth)) }, onClick = { menu = false; onRefreshAuth(service) })
        }
    }
}

@Composable
private fun signInLabel(value: String): String? = when (value) {
    "signedIn", "authorized" -> stringResource(R.string.signed_in)
    "signedOut", "notAuthorized" -> stringResource(R.string.signed_out)
    else -> null
}
