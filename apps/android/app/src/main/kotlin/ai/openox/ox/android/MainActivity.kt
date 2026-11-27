package ai.openox.ox.android

import ai.openox.ox.BuildConfig
import ai.openox.ox.client.app.OxApp
import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.modelproviders.ModelProviders
import ai.openox.ox.runtime.rpc.AgentProbe
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val shared = MutableStateFlow<SharedContent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        OxLog.attach(filesDir)
        if (savedInstanceState == null) receive(intent)
        probe(intent)
        overrideEndpoints(intent)
        setContent {
            OxApp(shared, onShareConsumed = { shared.value = null })
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
        probe(intent)
    }

    private fun probe(intent: Intent) {
        val prompt = intent.getStringExtra(AGENT_PROBE_EXTRA)?.takeIf { BuildConfig.DEBUG } ?: return
        lifecycleScope.launch { AgentProbe.run(applicationContext, prompt) }
    }

    private fun overrideEndpoints(intent: Intent) {
        val overrides = intent.getStringExtra(PROVIDER_ENDPOINTS_EXTRA)?.takeIf { BuildConfig.DEBUG } ?: return
        ModelProviders.get(applicationContext).apply {
            endpointOverrides = overrides.split(',').mapNotNull { pair -> pair.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }.toMap()
            refresh()
        }
        OxLog.info("providers.endpoints.overridden", "count" to overrides.split(',').size)
    }

    private fun receive(intent: Intent) {
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> return
        }
        val text = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getStringExtra(Intent.EXTRA_TEXT)).joinToString("\n").trim()
        if (text.isEmpty() && uris.isEmpty()) return
        OxLog.info("share.received", "chars" to text.length, "files" to uris.size)
        shared.value = SharedContent(text, uris)
    }

    private companion object {
        const val AGENT_PROBE_EXTRA = "ox.debug.agentProbe"
        const val PROVIDER_ENDPOINTS_EXTRA = "ox.debug.providerEndpoints"
    }
}
