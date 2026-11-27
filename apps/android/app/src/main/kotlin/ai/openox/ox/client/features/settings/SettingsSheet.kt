package ai.openox.ox.client.features.settings

import ai.openox.ox.BuildConfig
import ai.openox.ox.R
import ai.openox.ox.android.Platform
import ai.openox.ox.client.HostState
import ai.openox.ox.client.ProvidersState
import ai.openox.ox.client.features.providers.ModelSheet
import ai.openox.ox.client.features.providers.ProvidersSheet
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.LoadingRow
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.MessageRow
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSheet
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.SearchField
import ai.openox.ox.client.ui.SettingsGroup
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.SettingsScaffold
import ai.openox.ox.client.ui.TextDialog
import ai.openox.ox.runtime.modelproviders.ModelProviders
import ai.openox.ox.runtime.services.Services
import ai.openox.ox.runtime.services.string
import ai.openox.ox.platform.models.HostEndpoint
import ai.openox.ox.remote.ProfileRow
import ai.openox.ox.remote.ServiceRow
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun LogsPage(model: SettingsViewModel, onBack: () -> Unit) {
    val logs by model.logs.collectAsStateWithLifecycle()
    var level by rememberSaveable { mutableStateOf<String?>(null) }
    val search = rememberTextFieldState()
    val query = search.text.toString()
    LaunchedEffect(level, query) { model.loadLogs(level, query) }
    SettingsScaffold(stringResource(R.string.logs), "settings.logsPage", onBack = onBack, scroll = false) {
        SearchField(search, stringResource(R.string.search_logs), "settings.logs.search", inset = 0.dp, fill = MaterialTheme.colorScheme.surface)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
            listOf(null, "error", "warning", "info", "debug").forEach { option ->
                ChipButton(option ?: stringResource(R.string.all), "settings.logs.level.${option ?: "all"}",
                    style = if (option == level) ChipStyle.Primary else ChipStyle.Secondary) { level = option }
            }
        }
        when (val state = logs) {
            Loadable.Loading -> LoadingRow()
            is Loadable.Failed -> MessageRow(state.message)
            is Loadable.Loaded -> LazyColumn(
                modifier = Modifier.fillMaxWidth().weight(1f).background(MaterialTheme.colorScheme.surface, RoundedCornerShape(24.dp)),
                contentPadding = PaddingValues(vertical = OxSpacing.sm),
            ) {
                items(state.value.rows, key = { it.seq }) { row ->
                    Column(Modifier.fillMaxWidth().padding(horizontal = OxSpacing.lg, vertical = OxSpacing.sm)) {
                        Text("${row.time.substringAfter('T').take(12)} · ${row.level} · ${row.category}", style = MaterialTheme.typography.labelMedium,
                            color = if (row.level == "error") MaterialTheme.colorScheme.error else LocalOxColors.current.secondary)
                        Text(row.message, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace))
                    }
                }
                if (state.value.cursor != null) item {
                    Box(Modifier.fillMaxWidth().padding(OxSpacing.md)) {
                        ChipButton(stringResource(R.string.load_more), "settings.logs.more", Modifier.size(width = 160.dp, height = 44.dp), onClick = model::moreLogs)
                    }
                }
            }
        }
    }
}

enum class Appearance(val key: String, val label: Int) { System("system", R.string.appearance_system), Light("light", R.string.appearance_light), Dark("dark", R.string.appearance_dark) }

data class SettingsEnvironment(
    val host: HostState,
    val providers: ProvidersState,
    val services: List<ServiceRow>,
    val appearance: Appearance,
    val onAppearance: (Appearance) -> Unit,
    val onChangeHost: () -> Unit,
    val onProvidersChanged: () -> Unit,
    val onOpen: (SettingsPage) -> Unit,
    val onClose: () -> Unit,
)

sealed interface SettingsPage {
    data object Profile : SettingsPage
    data object Memory : SettingsPage
    data object Files : SettingsPage
    data object Skills : SettingsPage
    data object Services : SettingsPage
    data object Repositories : SettingsPage
    data object Logs : SettingsPage
}

@Composable
fun SettingsScreen(model: SettingsViewModel, environment: SettingsEnvironment, platform: Platform) {
    val profile by model.profile.collectAsStateWithLifecycle()
    val repositories by model.repositories.collectAsStateWithLifecycle()
    var choosingAppearance by remember { mutableStateOf(false) }
    var choosingProviders by remember { mutableStateOf(false) }
    var choosingDefault by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val local = (environment.host as? HostState.Connected)?.endpoint is HostEndpoint.Local
    val uri = LocalUriHandler.current
    LaunchedEffect(model) {
        if (model.supports("profile.inspect")) model.loadProfile()
        if (model.supports("repositories.list")) model.loadRepositories()
    }
    LaunchedEffect(model) { model.messages.collect { platform.toast(it) } }
    SettingsScaffold(stringResource(R.string.settings), "settings", onClose = environment.onClose) {
        if (model.supports("profile.inspect")) SettingsGroup(stringResource(R.string.profile)) {
            when (val state = profile) {
                Loadable.Loading -> LoadingRow()
                is Loadable.Failed -> MessageRow(state.message)
                is Loadable.Loaded -> SettingsRow(
                    icon = Icons.Outlined.PhoneIphone,
                    title = state.value.name,
                    subtitle = locationLabel(state.value),
                    tag = "settings.activeProfile",
                ) { environment.onOpen(SettingsPage.Profile) }
            }
        }
        SettingsGroup(stringResource(R.string.models)) {
            SettingsRow(Icons.Outlined.Tune, stringResource(R.string.default_model), value = (environment.providers as? ProvidersState.Loaded)?.defaultModel?.name ?: "—",
                tag = "settings.defaultModel", chevron = local, onClick = if (local) ({ choosingDefault = true }) else null)
            if (local) SettingsRow(Icons.Outlined.Hub, stringResource(R.string.providers), tag = "settings.providers") { choosingProviders = true }
        }
        SettingsGroup(stringResource(R.string.connections)) {
            SettingsRow(Icons.Outlined.GridView, stringResource(R.string.services), value = environment.services.size.toString(), tag = "settings.services") { environment.onOpen(SettingsPage.Services) }
            if (model.supports("repositories.list")) {
                val enabled = (repositories as? Loadable.Loaded)?.value?.count { it.enabled }
                SettingsRow(Icons.Outlined.Inventory2, stringResource(R.string.repositories), value = enabled?.let { pluralStringResource(R.plurals.repositories_enabled, it, it) },
                    tag = "settings.repositories") { environment.onOpen(SettingsPage.Repositories) }
            }
        }
        SettingsGroup(stringResource(R.string.ox_host)) {
            val host = environment.host
            SettingsRow(Icons.Outlined.Lan, (host as? HostState.Connected)?.description?.implementation?.let { "${it.name} ${it.version}" } ?: stringResource(R.string.ox_host),
                subtitle = when (host) {
                    is HostState.Connected -> if (host.endpoint is HostEndpoint.Local) stringResource(R.string.host_local_name) else host.endpoint.url
                    is HostState.Connecting -> host.endpoint.url
                    is HostState.Failed -> host.message
                    HostState.NotConfigured -> null
                }, tag = "settings.host", chevron = false, onClick = null)
            SettingsRow(Icons.Outlined.Hub, stringResource(R.string.host_change), tag = "settings.host.change", tint = MaterialTheme.colorScheme.primary, chevron = false, onClick = environment.onChangeHost)
        }
        SettingsGroup(stringResource(R.string.app)) {
            SettingsRow(Icons.Outlined.Palette, stringResource(R.string.appearance), value = stringResource(environment.appearance.label), tag = "settings.appearance") { choosingAppearance = true }
            if (model.supports("logs.list")) {
                SettingsRow(Icons.AutoMirrored.Outlined.Article, stringResource(R.string.logs), tag = "settings.logs") { environment.onOpen(SettingsPage.Logs) }
            }
            SettingsRow(Icons.Outlined.IosShare, stringResource(R.string.app_logs_share), tag = "settings.appLogs", chevron = false) { platform.shareLogs() }
        }
        SettingsGroup(stringResource(R.string.community)) {
            SettingsRow(Icons.Outlined.Forum, "Discord", tag = "settings.discord", chevron = false) { uri.openUri(DISCORD) }
            SettingsRow(Icons.Outlined.Code, "GitHub", tag = "settings.github", chevron = false) { uri.openUri(GITHUB) }
        }
        Text(
            stringResource(R.string.app_version, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
            style = MaterialTheme.typography.bodySmall,
            color = LocalOxColors.current.muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(vertical = OxSpacing.lg).testTag("settings.appVersion"),
        )
    }
    if (choosingProviders) ProvidersSheet(platform, environment.onProvidersChanged) { choosingProviders = false }
    if (choosingDefault) {
        ModelSheet(
            environment.providers, (environment.providers as? ProvidersState.Loaded)?.defaultModel, onLoad = {},
            onChoose = { chosen ->
                ModelProviders.get(context).defaultModel = chosen.providerId to chosen.modelId
                environment.onProvidersChanged()
                choosingDefault = false
            },
            onDismiss = { choosingDefault = false },
            title = stringResource(R.string.default_model),
            onSetUp = {
                choosingDefault = false
                choosingProviders = true
            },
        )
    }
    if (choosingAppearance) {
        OxSheet({ choosingAppearance = false }, stringResource(R.string.appearance), "settings.appearanceSheet") {
            Column(Modifier.navigationBarsPadding().padding(bottom = OxSpacing.xl)) {
                Appearance.entries.forEach { option ->
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { environment.onAppearance(option); choosingAppearance = false }
                            .padding(horizontal = OxSpacing.xl, vertical = 14.dp).testTag("settings.appearance.${option.key}"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(stringResource(option.label), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        if (option == environment.appearance) Icon(Icons.Filled.Check, null, tint = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
    }
}

@Composable
fun locationLabel(profile: ProfileRow): String = when (profile.location) {
    "local" -> stringResource(R.string.location_local)
    "iCloud", "icloud" -> stringResource(R.string.location_icloud)
    else -> stringResource(R.string.location_external)
}

private const val DISCORD = "https://discord.gg/Sre9DaKAAg"

private const val GITHUB = "https://github.com/ziyzhu/openox"
