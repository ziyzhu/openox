package ai.openox.ox.client.features.onboarding

import ai.openox.ox.R
import ai.openox.ox.client.HostState
import ai.openox.ox.client.HostViewModel
import ai.openox.ox.client.app.OxMark
import ai.openox.ox.client.ui.ChipButton
import ai.openox.ox.client.ui.ChipStyle
import ai.openox.ox.client.ui.LocalOxColors
import ai.openox.ox.client.ui.Outlined
import ai.openox.ox.client.ui.OxSpacing
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.ViewInAr
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun HostScreen(model: HostViewModel, onConnected: () -> Unit) {
    val host by model.host.collectAsStateWithLifecycle()
    val address = rememberTextFieldState(model.remoteAddress)
    var inputError by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(host) { if (host is HostState.Connected) onConnected() }
    LaunchedEffect(address) { snapshotFlow { address.text.toString() }.collect { inputError = null } }
    val connect = { inputError = model.connect(address.text.toString()).exceptionOrNull()?.message }
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = OxSpacing.xl, vertical = OxSpacing.xl),
            verticalArrangement = Arrangement.spacedBy(OxSpacing.xl),
        ) {
            OxMark(Modifier.size(48.dp).padding(top = OxSpacing.sm), color = MaterialTheme.colorScheme.primary, faint = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f))
            Text(stringResource(R.string.onboarding_title), style = MaterialTheme.typography.displayLarge)
            Column(verticalArrangement = Arrangement.spacedBy(OxSpacing.lg)) {
                Feature(Icons.Outlined.Language, R.string.onboarding_connect_title, R.string.onboarding_connect_detail)
                Feature(Icons.Outlined.PhoneIphone, R.string.onboarding_yours_title, R.string.onboarding_yours_detail)
                Feature(Icons.Outlined.ViewInAr, R.string.onboarding_model_title, R.string.onboarding_model_detail)
            }
            Text(stringResource(R.string.host_explanation), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            Column(verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                Row(
                    modifier = Modifier.fillMaxWidth().background(LocalOxColors.current.chip, CircleShape).padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f)) {
                        if (address.text.isEmpty()) Text(stringResource(R.string.host_address_placeholder), color = LocalOxColors.current.muted, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
                        BasicTextField(
                            state = address,
                            lineLimits = TextFieldLineLimits.SingleLine,
                            textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                            onKeyboardAction = { connect() },
                            modifier = Modifier.fillMaxWidth().testTag("host.address"),
                        )
                    }
                }
                val status = when (val state = host) {
                    is HostState.Failed -> state.message
                    else -> inputError
                }
                status?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(horizontal = OxSpacing.md).testTag("host.error")) }
            }
            Text(stringResource(R.string.onboarding_caution), style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary)
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (host is HostState.Connecting) {
                    CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp)
                } else {
                    ChipButton(stringResource(R.string.host_connect), "host.connect", Modifier.fillMaxWidth().widthIn(max = 480.dp), style = ChipStyle.Primary, height = 52.dp, fill = true,
                        enabled = address.text.isNotBlank(), onClick = connect)
                }
            }
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
                ChipButton(stringResource(R.string.host_local), "host.local", Modifier.fillMaxWidth().widthIn(max = 480.dp), height = 52.dp, fill = true,
                    enabled = host !is HostState.Connecting, onClick = model::useThisDevice)
                Text(stringResource(R.string.host_local_detail), style = MaterialTheme.typography.bodySmall, color = LocalOxColors.current.muted, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun Feature(icon: ImageVector, title: Int, detail: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(OxSpacing.lg)) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(detail), style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary)
        }
    }
}

@Composable
fun HostUnavailable(host: HostState, onRetry: () -> Unit, onChangeHost: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(LocalOxColors.current.conversationSurface).padding(OxSpacing.xl),
        verticalArrangement = Arrangement.spacedBy(OxSpacing.lg, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (host) {
            is HostState.Failed -> {
                Text(stringResource(R.string.host_unreachable), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
                Text(host.message, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary, textAlign = TextAlign.Center, modifier = Modifier.testTag("host.error"))
                ChipButton(stringResource(R.string.host_retry), "host.retry", style = ChipStyle.Primary, onClick = onRetry)
                ChipButton(stringResource(R.string.host_change), "host.change", onClick = onChangeHost)
            }
            else -> CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.5.dp)
        }
    }
}
