package ai.openox.ox.client.features.providers

import ai.openox.ox.R
import ai.openox.ox.android.MainActivity
import ai.openox.ox.android.Platform
import ai.openox.ox.client.automation.automation
import ai.openox.ox.client.features.services.ServiceAvatar
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.ConfirmDialog
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSheet
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.client.ui.SectionHeader
import ai.openox.ox.client.ui.SettingsRow
import ai.openox.ox.client.ui.TextDialog
import ai.openox.ox.runtime.agent.llm.providers.chatgpt.ChatGptAccount
import ai.openox.ox.runtime.agent.llm.providers.chatgpt.ChatGptFailure
import ai.openox.ox.runtime.modelproviders.ModelDefinition
import ai.openox.ox.runtime.modelproviders.ModelProviders
import ai.openox.ox.runtime.modelproviders.ProviderEntry
import ai.openox.ox.runtime.services.string
import android.content.Intent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@Composable
fun ProvidersSheet(platform: Platform, onChanged: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val providers = remember { ModelProviders.get(context) }
    val entries by providers.entries.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<ProviderEntry?>(null) }
    var adding by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf<ProviderEntry?>(null) }
    var signIn by remember { mutableStateOf<Job?>(null) }
    var region by remember { mutableStateOf(providers.region) }
    var iconsLoaded by remember { mutableIntStateOf(0) }
    val account by providers.chatGpt.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    LaunchedEffect(entries) {
        providers.icons.warm(entries.mapNotNull { it.iconUrl })
        iconsLoaded += 1
    }
    val open = { entry: ProviderEntry ->
        when (account) {
            is ChatGptAccount.State.SignedIn -> leaving = entry
            ChatGptAccount.State.SigningIn -> signIn?.cancel()
            ChatGptAccount.State.SignedOut -> signIn = scope.launch {
                try {
                    providers.chatGpt.signIn(
                        open = { address -> CustomTabsIntent.Builder().build().launchUrl(context, address) },
                        returned = { context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)) },
                    )
                } catch (error: ChatGptFailure) {
                    platform.error(error.message ?: platform.string(R.string.provider_sign_in))
                } finally {
                    providers.refresh()
                    onChanged()
                }
            }
        }
    }
    val accounts = entries.filter { it.account }
    val keyed = entries.filter { !it.account && !it.custom }.sortedWith(compareBy({ it.offer?.priority ?: Int.MAX_VALUE }, { it.definition.name.lowercase() }))
    val custom = entries.filter { it.custom }
    OxSheet(onDismiss, stringResource(R.string.providers), "settings.providersSheet") {
        LazyColumn(Modifier.navigationBarsPadding().padding(bottom = OxSpacing.xl)) {
            item(key = "region") {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = OxSpacing.sm),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
                ) {
                    Text(stringResource(R.string.provider_region), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    ModelProviders.REGIONS.forEach { option ->
                        ChipButton(
                            text = stringResource(if (option == "china") R.string.provider_region_china else R.string.provider_region_global),
                            tag = "settings.providerRegion.$option",
                            style = if (region == option) ChipStyle.Primary else ChipStyle.Secondary,
                        ) {
                            region = option
                            providers.region = option
                            onChanged()
                        }
                    }
                }
            }
            if (accounts.isNotEmpty()) item(key = "accounts") { SectionHeader(stringResource(R.string.provider_accounts)) }
            items(accounts, key = { it.definition.id }) { entry ->
                ProviderRow(
                    entry, providers, iconsLoaded,
                    subtitle = when (val state = account) {
                        is ChatGptAccount.State.SignedIn -> state.email?.let { stringResource(R.string.provider_signed_in_as, it) } ?: stringResource(R.string.provider_signed_in)
                        ChatGptAccount.State.SigningIn -> stringResource(R.string.provider_signing_in)
                        ChatGptAccount.State.SignedOut -> stringResource(R.string.provider_sign_in)
                    },
                ) { open(entry) }
            }
            if (keyed.isNotEmpty()) item(key = "keyed") { SectionHeader(stringResource(R.string.provider_api)) }
            items(keyed, key = { it.definition.id }) { entry ->
                ProviderRow(
                    entry, providers, iconsLoaded,
                    subtitle = if (entry.hasKey) stringResource(R.string.provider_key_saved) else entry.offer?.summary ?: stringResource(R.string.provider_api_key),
                ) { editing = entry }
            }
            item(key = "custom") { SectionHeader(stringResource(R.string.provider_custom)) }
            items(custom, key = { it.definition.id }) { entry ->
                ProviderRow(entry, providers, iconsLoaded, subtitle = entry.definition.url, onRemove = {
                    providers.removeCustom(entry.definition.id)
                    onChanged()
                }) { editing = entry }
            }
            item(key = "add") {
                SettingsRow(Icons.Outlined.Add, stringResource(R.string.provider_add), subtitle = stringResource(R.string.provider_add_detail), tag = "settings.provider.add",
                    tint = MaterialTheme.colorScheme.primary, chevron = false) { adding = true }
            }
        }
    }
    editing?.let { entry ->
        TextDialog(
            stringResource(R.string.provider_key_title, entry.definition.name), "", stringResource(R.string.save), "settings.providerKey",
            onConfirm = { value ->
                providers.setKey(entry.definition.id, value)
                onChanged()
            },
            secret = true,
            help = {
                Text(
                    entry.notice ?: stringResource(R.string.provider_key_detail),
                    style = MaterialTheme.typography.bodySmall, color = LocalOxColors.current.secondary,
                )
                entry.website?.let { website ->
                    TextButton(onClick = { CustomTabsIntent.Builder().build().launchUrl(context, website.toUri()) }, modifier = Modifier.testTag("settings.providerKey.website")) {
                        Text(stringResource(R.string.provider_get_key))
                    }
                }
                if (entry.hasKey) TextButton(
                    onClick = {
                        providers.setKey(entry.definition.id, "")
                        onChanged()
                        editing = null
                    },
                    modifier = Modifier.testTag("settings.providerKey.remove"),
                ) { Text(stringResource(R.string.provider_key_remove), color = MaterialTheme.colorScheme.error) }
            },
        ) { editing = null }
    }
    leaving?.let { entry ->
        ConfirmDialog(
            stringResource(R.string.provider_sign_out_title, entry.definition.name), stringResource(R.string.provider_sign_out_detail),
            stringResource(R.string.provider_sign_out), "settings.providerSignOut",
            onConfirm = {
                scope.launch {
                    providers.chatGpt.signOut()
                    providers.refresh()
                    onChanged()
                }
            },
        ) { leaving = null }
    }
    if (adding) CustomProviderDialog(providers, onAdded = onChanged) { adding = false }
}

@Composable
private fun ProviderRow(entry: ProviderEntry, providers: ModelProviders, iconsLoaded: Int, subtitle: String?, onRemove: (() -> Unit)? = null, onClick: () -> Unit) {
    val icon = remember(entry.iconUrl, iconsLoaded) { providers.icons.cached(entry.iconUrl) }
    SettingsRow(
        icon = null,
        title = entry.definition.name,
        subtitle = subtitle,
        tag = "settings.provider.${entry.definition.id}",
        chevron = false,
        leading = { ServiceAvatar(entry.definition.name, icon, 32.dp) },
        trailing = {
            if (entry.hasKey) Icon(Icons.Filled.Check, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            if (onRemove != null) IconButton(onClick = onRemove, modifier = Modifier.testTag("settings.provider.remove.${entry.definition.id}")) {
                Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.provider_remove), modifier = Modifier.size(20.dp))
            }
        },
        onClick = onClick,
    )
}

private sealed interface ModelProbe {
    data object Idle : ModelProbe
    data object Loading : ModelProbe
    data class Found(val address: String, val models: List<ModelDefinition>) : ModelProbe
    data class Failed(val message: String) : ModelProbe
}

@Composable
private fun CustomProviderDialog(providers: ModelProviders, onAdded: () -> Unit, onDismiss: () -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var address by rememberSaveable { mutableStateOf("https://") }
    val key = rememberTextFieldState()
    var probe by remember { mutableStateOf<ModelProbe>(ModelProbe.Idle) }
    val scope = rememberCoroutineScope()
    val found = probe as? ModelProbe.Found
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.provider_add)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                OutlinedTextField(
                    value = name, onValueChange = { name = it }, singleLine = true, shape = MaterialTheme.shapes.medium,
                    label = { Text(stringResource(R.string.provider_name)) }, modifier = Modifier.fillMaxWidth().testTag("settings.providerAdd.name"),
                )
                OutlinedTextField(
                    value = address,
                    onValueChange = {
                        address = it
                        probe = ModelProbe.Idle
                    },
                    singleLine = true, shape = MaterialTheme.shapes.medium,
                    label = { Text(stringResource(R.string.provider_address)) },
                    supportingText = { Text(stringResource(R.string.provider_address_detail)) },
                    modifier = Modifier.fillMaxWidth().testTag("settings.providerAdd.field"),
                )
                OutlinedSecureTextField(
                    state = key, shape = MaterialTheme.shapes.medium, label = { Text(stringResource(R.string.provider_key_optional)) },
                    modifier = Modifier.fillMaxWidth().testTag("settings.providerAdd.key"),
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                    TextButton(
                        enabled = probe != ModelProbe.Loading,
                        onClick = {
                            probe = ModelProbe.Loading
                            scope.launch {
                                val target = providers.normalized(address)
                                probe = target.fold(
                                    onSuccess = { url ->
                                        providers.models(url, key.text.toString()).fold({ ModelProbe.Found(url, it) }, { ModelProbe.Failed(it.message ?: it.javaClass.simpleName) })
                                    },
                                    onFailure = { ModelProbe.Failed(it.message ?: it.javaClass.simpleName) },
                                )
                            }
                        },
                        modifier = Modifier.testTag("settings.providerAdd.load"),
                    ) { Text(stringResource(R.string.provider_load_models)) }
                    when (val state = probe) {
                        ModelProbe.Idle -> Unit
                        ModelProbe.Loading -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        is ModelProbe.Found -> Text(
                            pluralStringResource(R.plurals.provider_models_found, state.models.size, state.models.size),
                            style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary, modifier = Modifier.testTag("settings.providerAdd.found"),
                        )
                        is ModelProbe.Failed -> Text(
                            state.message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("settings.providerAdd.error"),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank() && found != null,
                onClick = {
                    found?.let { providers.addCustom(name, it.address, key.text.toString(), it.models) }
                    onAdded()
                    onDismiss()
                },
                modifier = Modifier.testTag("settings.providerAdd.confirm"),
            ) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = MaterialTheme.colorScheme.surface,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.automation().testTag("settings.providerAdd"),
    )
}
