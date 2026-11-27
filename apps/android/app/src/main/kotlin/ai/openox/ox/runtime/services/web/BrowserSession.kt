package ai.openox.ox.runtime.services.web

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.services.web.publicweb.PublicAddress
import ai.openox.ox.runtime.vm.OxFunctionError
import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.net.http.SslError
import android.view.ViewGroup
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

class BrowserPages private constructor(private val application: Context) {
    class Presentation(val pageId: String, val view: WebView, val context: MutableContextWrapper, val host: String, private val outcome: CompletableDeferred<Boolean>) {
        fun finish(completed: Boolean) {
            outcome.complete(completed)
        }
    }

    class Frame(val id: String, val origin: String) {
        val host: String get() = origin.toHttpUrlOrNull()?.host.orEmpty()
    }

    private class Page(val id: String, val owner: Int, val context: MutableContextWrapper, val view: WebView) {
        var generation = 0
        var lastActive = System.currentTimeMillis()
        var busy = 0
        var loading = false
        var presented = false
        var failure: String? = null
        var navigation: CompletableDeferred<Unit>? = null
        var frame: Frame? = null
        val replies = HashMap<String, CompletableDeferred<JsonObject>>()
    }

    private val pages = LinkedHashMap<String, Page>()
    private val shown = MutableStateFlow<Presentation?>(null)

    val presentation: StateFlow<Presentation?> = shown

    suspend fun open(owner: Int, url: String): JsonObject {
        val address = destination(url)
        return withContext(Dispatchers.Main.immediate) {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                throw OxFunctionError("unavailable", "This device's WebView is too old for the Browser; update Android System WebView")
            }
            if (pages.size >= LIMIT) {
                val idle = pages.values.filter { it.busy == 0 && !it.presented }.minByOrNull { it.lastActive }
                    ?: throw OxFunctionError("limit_exceeded", "All $LIMIT pages are busy; wait or close a page")
                destroy(idle)
            }
            val page = create(owner)
            pages[page.id] = page
            load(page) { page.view.loadUrl(address.toString()) }
            OxLog.info("browser.page.opened", "page" to page.id, "host" to address.host, "pages" to pages.size)
            buildJsonObject {
                put("pageId", page.id)
                put("mainFrameId", page.frame?.id ?: throw OxFunctionError("frame_unavailable", "The page loaded without an inspectable document"))
            }
        }
    }

    suspend fun navigate(owner: Int, pageId: String, url: String): JsonObject {
        val address = destination(url)
        return withContext(Dispatchers.Main.immediate) {
            val page = owned(owner, pageId)
            load(page) { page.view.loadUrl(address.toString()) }
            located(page)
        }
    }

    suspend fun reload(owner: Int, pageId: String): JsonObject = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        load(page) { page.view.reload() }
        located(page)
    }

    suspend fun travel(owner: Int, pageId: String, forward: Boolean): JsonObject = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        val possible = if (forward) page.view.canGoForward() else page.view.canGoBack()
        if (possible) load(page) { if (forward) page.view.goForward() else page.view.goBack() }
        buildJsonObject {
            put("navigated", possible)
            put("url", page.view.url)
        }
    }

    suspend fun awaitUrl(owner: Int, pageId: String, pattern: String?, timeoutMs: Long): JsonObject = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        val generation = page.generation
        val matcher = pattern?.let { Regex(it.split('*').joinToString(".*") { part -> Regex.escape(part) }) }
        val arrived = withTimeoutOrNull(timeoutMs) {
            while (page.loading || (matcher?.matches(page.view.url.orEmpty()) ?: (page.generation != generation)) == false) delay(POLL_MS)
            true
        }
        if (arrived == null) throw OxFunctionError("timeout", "The page did not reach the expected URL in $timeoutMs ms; it is at ${page.view.url}")
        identify(page)
        located(page)
    }

    suspend fun frames(owner: Int, pageId: String): List<Frame> = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        identify(page)
        listOfNotNull(page.frame)
    }

    suspend fun frame(owner: Int, frameId: String): Frame = withContext(Dispatchers.Main.immediate) { target(owner, frameId).frame ?: throw stale() }

    suspend fun evaluate(owner: Int, frameId: String, script: String, timeoutMs: Long = EVALUATE_MS): JsonElement = withContext(Dispatchers.Main.immediate) {
        val page = target(owner, frameId)
        val frame = page.frame ?: throw stale()
        if (page.presented) throw OxFunctionError("busy", "The page is waiting for the user; wait for showPage to return")
        page.busy += 1
        try {
            val guard = "if (window.__oxDocumentID !== ${JsonPrimitive(frame.id)} || location.origin !== ${JsonPrimitive(frame.origin)}) throw Error('Frame document changed; inspect the page again');"
            run(page, "$guard\n$script", timeoutMs)
        } finally {
            page.busy -= 1
            page.lastActive = System.currentTimeMillis()
        }
    }

    suspend fun snapshot(owner: Int, frameId: String, selector: String?): JsonObject {
        val document = evaluate(owner, frameId, "const selector = ${selector?.let { JsonPrimitive(it) } ?: JsonNull};\n$SNAPSHOT", SNAPSHOT_MS)
        return withContext(Dispatchers.Main.immediate) {
            val page = target(owner, frameId)
            buildJsonObject {
                put("pageID", page.id)
                put("navigationGeneration", page.generation)
                put("url", page.view.url)
                put("title", page.view.title.orEmpty())
                put("estimatedProgress", page.view.progress / 100.0)
                put("isLoading", page.loading)
                put("hasOnlySecureContent", page.view.url?.startsWith("https://") == true)
                put("isBlockedByScreenTime", false)
                put("fullscreenState", "notInFullscreen")
                put("frameId", frameId)
                put("document", document)
            }
        }
    }

    suspend fun present(owner: Int, pageId: String): Boolean = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        if (shown.value != null) throw OxFunctionError("busy", "Another page is already being shown to the user")
        val outcome = CompletableDeferred<Boolean>()
        page.presented = true
        shown.value = Presentation(page.id, page.view, page.context, page.view.url?.toHttpUrlOrNull()?.host.orEmpty(), outcome)
        OxLog.info("browser.page.presented", "page" to page.id)
        try {
            outcome.await()
        } finally {
            shown.value = null
            page.presented = false
            (page.view.parent as? ViewGroup)?.removeView(page.view)
            page.context.baseContext = application
            page.frame = null
            page.lastActive = System.currentTimeMillis()
            OxLog.info("browser.page.returned", "page" to page.id)
        }
    }

    suspend fun close(owner: Int, pageId: String): Boolean = withContext(Dispatchers.Main.immediate) {
        val page = owned(owner, pageId)
        if (page.busy > 0 || page.presented) throw OxFunctionError("busy", "The page is busy or waiting for the user")
        destroy(page)
        true
    }

    suspend fun release(owner: Int) = withContext(Dispatchers.Main.immediate) {
        pages.values.filter { it.owner == owner }.forEach(::destroy)
    }

    suspend fun list(owner: Int): JsonArray = withContext(Dispatchers.Main.immediate) {
        buildJsonArray {
            pages.values.sortedBy { it.lastActive }.forEach { page ->
                val mine = page.owner == owner
                addJsonObject {
                    put("pageId", page.id)
                    put("url", if (mine) page.view.url else page.view.url?.toHttpUrlOrNull()?.let { "${it.scheme}://${it.host}" })
                    put("title", if (mine) page.view.title.orEmpty() else "")
                    put("isLoading", page.loading)
                    put("busy", page.busy > 0 || page.presented)
                    put("owned", mine)
                    put("lastActiveAt", Instant.ofEpochMilli(page.lastActive).toString())
                }
            }
        }
    }

    private suspend fun destination(url: String): HttpUrl {
        val address = url.toHttpUrlOrNull()?.takeIf { it.isHttps } ?: throw OxFunctionError("invalid_argument", "Provide an absolute public HTTPS URL")
        try {
            PublicAddress.require(address.host)
        } catch (error: java.io.IOException) {
            throw OxFunctionError("navigation_failed", "Could not open ${address.host}: ${error.message}")
        }
        return address
    }

    private fun owned(owner: Int, pageId: String): Page =
        pages[pageId]?.takeIf { it.owner == owner } ?: throw OxFunctionError("page_unavailable", "The page is closed or belongs to another conversation; list pages and open a new one if needed")

    private fun target(owner: Int, frameId: String): Page =
        pages.values.firstOrNull { it.owner == owner && it.frame?.id == frameId } ?: throw stale()

    private fun stale() = OxFunctionError("frame_unavailable", "The frame is unavailable. List the page's frames again and use a fresh frameId")

    private fun located(page: Page) = buildJsonObject { put("url", page.view.url) }

    private suspend fun load(page: Page, start: () -> Unit) {
        if (page.presented) throw OxFunctionError("busy", "The page is waiting for the user; wait for showPage to return")
        page.busy += 1
        try {
            val finished = CompletableDeferred<Unit>()
            page.navigation = finished
            page.failure = null
            start()
            val completed = withTimeoutOrNull(NAVIGATION_MS) { finished.await() } != null
            page.navigation = null
            page.failure?.let { throw OxFunctionError("navigation_failed", "The page could not load: $it") }
            if (!completed) OxLog.warning("browser.navigation.slow", "page" to page.id)
            identify(page)
        } finally {
            page.busy -= 1
            page.lastActive = System.currentTimeMillis()
        }
    }

    private suspend fun identify(page: Page) {
        val identity = runCatching { run(page, IDENTITY, IDENTITY_MS) }.getOrNull() as? JsonObject
        val id = (identity?.get("id") as? JsonPrimitive)?.contentOrNull
        val origin = (identity?.get("origin") as? JsonPrimitive)?.contentOrNull
        page.frame = if (id != null && origin != null && origin.startsWith("https://")) Frame(id, origin) else null
    }

    private suspend fun run(page: Page, body: String, timeoutMs: Long): JsonElement {
        val id = UUID.randomUUID().toString()
        val reply = CompletableDeferred<JsonObject>()
        page.replies[id] = reply
        try {
            page.view.evaluateJavascript(WRAPPER.replace(ID_MARKER, id).replace(BODY_MARKER, body), null)
            val answer = withTimeoutOrNull(timeoutMs) { reply.await() } ?: throw OxFunctionError("timeout", "The page script did not finish in ${timeoutMs / 1000} seconds")
            (answer["error"] as? JsonPrimitive)?.contentOrNull?.let { throw OxFunctionError("script_failed", it) }
            return answer["value"] ?: JsonNull
        } finally {
            page.replies.remove(id)
        }
    }

    private fun invalidate(page: Page) {
        page.generation += 1
        page.frame = null
        page.replies.values.toList().forEach { it.complete(buildJsonObject { put("error", "Frame document changed; inspect the page again") }) }
    }

    private fun destroy(page: Page) {
        pages.remove(page.id)
        invalidate(page)
        page.navigation?.complete(Unit)
        (page.view.parent as? ViewGroup)?.removeView(page.view)
        page.view.stopLoading()
        page.view.destroy()
        OxLog.info("browser.page.closed", "page" to page.id, "pages" to pages.size)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun create(owner: Int): Page {
        val context = MutableContextWrapper(application)
        val view = WebView(context)
        val page = Page(UUID.randomUUID().toString().uppercase(), owner, context, view)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
        }
        view.layout(0, 0, VIEW_WIDTH, VIEW_HEIGHT)
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = request.url.scheme != "https"

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                page.loading = true
                invalidate(page)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                page.loading = false
                page.navigation?.complete(Unit)
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                page.failure = error.description?.toString() ?: "network error"
                page.navigation?.complete(Unit)
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
                page.failure = "the site's certificate is not trusted"
                page.navigation?.complete(Unit)
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                OxLog.warning("browser.renderer.gone", "page" to page.id, "crashed" to detail.didCrash())
                destroy(page)
                return true
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean = dismissed(result)

            override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean = dismissed(result)

            override fun onJsPrompt(view: WebView, url: String?, message: String?, defaultValue: String?, result: JsPromptResult): Boolean = dismissed(result)

            private fun dismissed(result: JsResult): Boolean {
                if (page.presented) return false
                result.cancel()
                return true
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(view, CHANNEL, setOf("*")) { _, message, _, isMainFrame, _ ->
                val answer = message.data?.takeIf { isMainFrame }?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() } as? JsonObject
                val id = (answer?.get("id") as? JsonPrimitive)?.contentOrNull
                if (answer != null && id != null) page.replies[id]?.complete(answer)
            }
        }
        return page
    }

    companion object {
        private const val LIMIT = 8
        private const val VIEW_WIDTH = 1080
        private const val VIEW_HEIGHT = 2160
        private const val NAVIGATION_MS = 30_000L
        private const val EVALUATE_MS = 30_000L
        private const val SNAPSHOT_MS = 5_000L
        private const val IDENTITY_MS = 3_000L
        private const val POLL_MS = 150L
        private const val CHANNEL = "__oxHost"
        private const val ID_MARKER = "__OX_REPLY_ID__"
        private const val BODY_MARKER = "__OX_BODY__"

        @Volatile
        private var instance: BrowserPages? = null

        fun get(context: Context): BrowserPages = instance ?: synchronized(this) {
            instance ?: BrowserPages(context.applicationContext).also { instance = it }
        }

        private val WRAPPER = """
            (() => {
              const id = "$ID_MARKER";
              const reply = payload => {
                try {
                  $CHANNEL.postMessage(JSON.stringify(payload));
                } catch (error) {
                  $CHANNEL.postMessage(JSON.stringify({ id, error: 'Result is not JSON-compatible: ' + String(error && error.message || error) }));
                }
              };
              (async () => {
            $BODY_MARKER
              })().then(
                value => reply({ id, value: value === undefined ? null : value }),
                error => reply({ id, error: String(error && error.message || error) })
              );
            })();
        """.trimIndent()

        private val IDENTITY = """
            if (!Object.hasOwn(window, '__oxDocumentID')) Object.defineProperty(window, '__oxDocumentID', { value: crypto.randomUUID() });
            return { id: window.__oxDocumentID, origin: location.origin };
        """.trimIndent()

        private val SNAPSHOT = """
            const clip = (text, size) => String(text ?? '').replace(/\s+/g, ' ').trim().slice(0, size);
            let scope = document.body;
            if (selector) {
              try { scope = document.querySelector(selector); } catch (error) { scope = null; }
            }
            const result = {
              scope: selector, scopeFound: !!scope, readyState: document.readyState, busy: false, headings: [], dialogs: [], messages: [],
              controls: [], embeddedFrames: [], truncated: false, coverage: 'Visible light-DOM elements in the selected scope; shadow roots and iframes are not included.',
            };
            if (!scope) return result;
            const visible = element => {
              if (!element.getClientRects().length) return false;
              const style = getComputedStyle(element);
              return style.visibility !== 'hidden' && style.display !== 'none';
            };
            const take = (query, limit, describe) => {
              const items = [];
              for (const element of scope.querySelectorAll(query)) {
                if (!visible(element)) continue;
                if (items.length >= limit) { result.truncated = true; break; }
                items.push(describe(element));
              }
              return items;
            };
            const roles = { a: 'link', button: 'button', select: 'combobox', textarea: 'textbox', summary: 'button' };
            const role = (element, tag) => element.getAttribute('role') || roles[tag]
              || (tag === 'input' ? (element.type === 'checkbox' || element.type === 'radio' ? element.type : /^(button|submit|reset)$/.test(element.type) ? 'button' : 'textbox') : 'generic');
            const label = (element, tag) => clip(element.getAttribute('aria-label') || (element.labels && element.labels[0] && element.labels[0].textContent)
              || element.getAttribute('placeholder') || element.getAttribute('title') || element.getAttribute('alt')
              || (tag === 'input' || tag === 'select' || tag === 'textarea' ? '' : element.textContent), 200);
            result.busy = !!scope.querySelector('[aria-busy="true"]');
            result.headings = take('h1,h2,h3,[role="heading"]', 40, element => clip(element.textContent, 200)).filter(Boolean);
            result.dialogs = take('dialog[open],[role="dialog"],[role="alertdialog"]', 10, element => {
              const heading = element.querySelector('h1,h2,h3');
              return { label: clip(element.getAttribute('aria-label') || (heading && heading.textContent), 200) };
            });
            result.messages = take('[role="alert"],[role="status"],[aria-live]', 20, element => clip(element.textContent, 300)).filter(Boolean);
            result.controls = take('a[href],button,input:not([type="hidden"]),select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],[role="tab"],[role="menuitem"],[role="combobox"],[role="switch"],[contenteditable="true"]', 150, element => {
              const tag = element.tagName.toLowerCase();
              const name = element.getAttribute('name');
              const control = {
                id: element.id ? element.id.slice(0, 256) : null, name: name ? name.slice(0, 256) : null, role: role(element, tag), label: label(element, tag),
                type: tag === 'input' ? element.type : tag, disabled: !!element.disabled || element.getAttribute('aria-disabled') === 'true',
                required: !!element.required || element.getAttribute('aria-required') === 'true', invalid: element.getAttribute('aria-invalid') === 'true',
              };
              if (tag === 'input' || tag === 'select' || tag === 'textarea') control.hasValue = !!element.value;
              if (element.type === 'checkbox' || element.type === 'radio' || element.hasAttribute('aria-checked')) control.checked = element.checked === true || element.getAttribute('aria-checked') === 'true';
              if (element.hasAttribute('aria-expanded')) control.expanded = element.getAttribute('aria-expanded') === 'true';
              if (element.hasAttribute('aria-selected')) control.selected = element.getAttribute('aria-selected') === 'true';
              return control;
            });
            result.embeddedFrames = take('iframe', 20, element => {
              let origin = null;
              try { origin = element.src ? new URL(element.src, location.href).origin : null; } catch (error) {}
              return { id: element.id || null, name: element.getAttribute('name'), title: element.title || '', origin };
            });
            return result;
        """.trimIndent()
    }
}
