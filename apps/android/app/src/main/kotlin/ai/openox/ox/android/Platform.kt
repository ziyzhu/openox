package ai.openox.ox.android

import ai.openox.ox.R
import ai.openox.ox.client.ui.ToastState
import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.services.string
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import android.speech.RecognizerIntent
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class Platform(
    private val context: Context,
    private val clipboard: Clipboard,
    private val scope: CoroutineScope,
    private val toasts: ToastState,
) {
    var onAttachments: (List<Pair<String, ByteArray>>) -> Unit = {}
    var onSpeech: (String) -> Unit = {}
    internal var launchPhotos: () -> Unit = {}
    internal var launchFiles: () -> Unit = {}
    internal var launchCamera: () -> Unit = {}
    internal var launchSpeech: () -> Unit = {}

    val speechAvailable: Boolean by lazy {
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).resolveActivity(context.packageManager) != null
    }

    fun string(id: Int): String = context.getString(id)

    fun toast(message: String) {
        scope.launch { toasts.show(message, error = false) }
    }

    fun error(message: String) {
        scope.launch { toasts.show(message, error = true) }
    }

    fun copy(text: String) {
        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Ox", text))) }
    }

    fun shareText(text: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        start(Intent.createChooser(send, null))
    }

    fun shareLogs() {
        scope.launch {
            val file = withContext(Dispatchers.IO) { OxLog.export() }
            if (file == null) {
                toast(string(R.string.app_logs_empty))
                return@launch
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            start(Intent.createChooser(send, null))
        }
    }

    fun pickPhotos() = launchPhotos()

    fun pickFiles() = launchFiles()

    fun takePhoto() = launchCamera()

    fun listen() = launchSpeech()

    fun openFile(name: String, bytes: ByteArray) {
        scope.launch {
            val file = withContext(Dispatchers.IO) {
                File(context.cacheDir, "shared").apply { mkdirs() }.resolve(name.replace('/', '_')).apply { writeBytes(bytes) }
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
            OxLog.info("file.open", "name" to name, "bytes" to bytes.size, "type" to type)
            start(Intent.createChooser(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), name))
        }
    }

    fun import(uris: List<Uri>) {
        if (uris.isEmpty()) return
        scope.launch {
            val files = withContext(Dispatchers.IO) {
                uris.mapNotNull { uri ->
                    runCatching {
                        val name = displayName(uri)
                        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@runCatching null
                        if (bytes.size > MAX_UPLOAD) null else name to bytes
                    }.onFailure { OxLog.warning("attachments.read.failed", "error" to it.javaClass.simpleName, "message" to it.message) }.getOrNull()
                }
            }
            if (files.size < uris.size) error(context.getString(R.string.attachment_skipped))
            OxLog.info("attachments.import", "count" to files.size, "skipped" to uris.size - files.size)
            onAttachments(files)
        }
    }

    internal fun importPhoto(bitmap: Bitmap?) {
        bitmap ?: return
        scope.launch {
            val bytes = withContext(Dispatchers.Default) {
                ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
            }
            onAttachments(listOf("Photo ${System.currentTimeMillis() / 1000}.jpg" to bytes))
        }
    }

    private fun displayName(uri: Uri): String =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: uri.lastPathSegment ?: "file"

    private fun start(intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            toast(context.getString(R.string.no_app))
        }
    }

    private companion object {
        const val MAX_UPLOAD = 20 * 1024 * 1024
    }
}

@Composable
fun rememberPlatform(toasts: ToastState): Platform {
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    val platform = remember(context) { Platform(context, clipboard, scope, toasts) }
    val prompt = stringResource(R.string.voice_prompt)
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { platform.import(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { platform.import(it) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicturePreview()) { platform.importPhoto(it) }
    val speech = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let(platform.onSpeech)
    }
    platform.launchPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }
    platform.launchFiles = { files.launch(arrayOf("*/*")) }
    platform.launchCamera = { camera.launch(null) }
    platform.launchSpeech = {
        speech.launch(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PROMPT, prompt),
        )
    }
    return platform
}
