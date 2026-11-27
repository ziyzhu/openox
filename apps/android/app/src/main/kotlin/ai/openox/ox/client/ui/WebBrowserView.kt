package ai.openox.ox.client.ui

import ai.openox.ox.R
import ai.openox.ox.runtime.services.string
import ai.openox.ox.runtime.services.web.BrowserPages
import android.view.ViewGroup
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun BrowserOverlay() {
    val pages = BrowserPages.get(LocalContext.current)
    val presentation by pages.presentation.collectAsStateWithLifecycle()
    val shown = presentation ?: return
    Dialog(onDismissRequest = { shown.finish(false) }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val view = LocalView.current
        val dark = isSystemInDarkTheme()
        SideEffect {
            (view.parent as? DialogWindowProvider)?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
        }
        Surface(modifier = Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }.testTag("browser.page"), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.systemBarsPadding().imePadding()) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = OxSpacing.sm), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { shown.finish(false) }, modifier = Modifier.testTag("browser.cancel")) { Text(stringResource(R.string.cancel)) }
                    Text(
                        shown.host,
                        style = MaterialTheme.typography.titleSmall,
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).testTag("browser.host"),
                    )
                    TextButton(onClick = { shown.finish(true) }, modifier = Modifier.testTag("browser.done")) { Text(stringResource(R.string.browser_done)) }
                }
                AndroidView(
                    factory = { context ->
                        shown.context.baseContext = context
                        (shown.view.parent as? ViewGroup)?.removeView(shown.view)
                        shown.view
                    },
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                )
            }
        }
    }
}
