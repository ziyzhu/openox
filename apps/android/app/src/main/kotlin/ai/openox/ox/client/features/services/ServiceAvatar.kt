package ai.openox.ox.client.features.services

import ai.openox.ox.client.ui.LocalOxColors
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Composable
fun ServiceAvatar(title: String, favicon: String?, size: Dp = 36.dp) {
    val image = remember(favicon) {
        favicon?.substringAfter("base64,", "")?.takeIf { it.isNotEmpty() }?.let { encoded ->
            runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull()
                ?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }?.asImageBitmap()
        }
    }
    Box(
        modifier = Modifier.size(size).clip(CircleShape).background(LocalOxColors.current.chip),
        contentAlignment = Alignment.Center,
    ) {
        if (image != null) Image(image, contentDescription = null, modifier = Modifier.size(size * 0.6f))
        else Text(title.take(1).uppercase(), style = if (size < 30.dp) MaterialTheme.typography.labelSmall else MaterialTheme.typography.titleSmall)
    }
}
