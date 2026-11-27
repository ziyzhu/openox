package ai.openox.ox.client.ui

import ai.openox.ox.R
import ai.openox.ox.runtime.services.string
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@Composable
internal fun NoticeToast(message: String, onDismiss: () -> Unit, modifier: Modifier) {
    Row(
        modifier = modifier.padding(horizontal = OxSpacing.lg).glass(RoundedCornerShape(24.dp)).padding(start = 14.dp).testTag("conversation.notice"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
        Text(message, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f, fill = false).padding(horizontal = OxSpacing.sm, vertical = 10.dp))
        TextButton(onClick = onDismiss) { Text(stringResource(R.string.dismiss), color = MaterialTheme.colorScheme.primary) }
    }
}

data class Toast(val message: String, val error: Boolean)

class ToastState {
    var current by mutableStateOf<Toast?>(null)
        private set
    private var generation = 0

    suspend fun show(text: String, error: Boolean) {
        val mine = ++generation
        current = Toast(text, error)
        delay(if (error) 4000 else 1800)
        if (generation == mine) current = null
    }
}

@Composable
fun ToastHost(state: ToastState, modifier: Modifier = Modifier) {
    AnimatedVisibility(
        visible = state.current != null,
        enter = fadeIn() + slideInVertically { -it / 2 },
        exit = fadeOut() + slideOutVertically { -it / 2 },
        modifier = modifier,
    ) {
        Row(
            modifier = Modifier.statusBarsPadding().padding(top = 60.dp, start = OxSpacing.lg, end = OxSpacing.lg)
                .glass(if (state.current?.error == true) RoundedCornerShape(24.dp) else CircleShape)
                .padding(horizontal = 14.dp, vertical = 10.dp).testTag("conversation.toast"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OxSpacing.sm),
        ) {
            val toast = state.current
            if (toast?.error == true) Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
            else Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
            Text(toast?.message.orEmpty(), style = MaterialTheme.typography.labelLarge)
        }
    }
}
