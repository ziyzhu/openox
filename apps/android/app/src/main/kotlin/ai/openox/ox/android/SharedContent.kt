package ai.openox.ox.android

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

data class SharedContent(val text: String, val uris: List<Uri>)
