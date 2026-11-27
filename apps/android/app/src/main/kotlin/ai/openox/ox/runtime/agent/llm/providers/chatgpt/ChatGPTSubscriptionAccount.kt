package ai.openox.ox.runtime.agent.llm.providers.chatgpt

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.modelproviders.ProviderKeys
import ai.openox.ox.runtime.services.string
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
import androidx.core.content.edit
import androidx.core.net.toUri
import java.io.IOException
import java.math.BigInteger
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.RSAPublicKeySpec
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

class ChatGptFailure(message: String, val expired: Boolean = false) : Exception(message)

@Serializable
data class ChatGptTokens(
    val accessToken: String,
    val refreshToken: String,
    val idToken: String,
    val clientId: String,
    val subject: String,
    val email: String? = null,
    val scopes: Set<String> = emptySet(),
    val expiresAtMs: Long = 0,
) {
    val usable: Boolean get() = accessToken.isNotEmpty() && "chatgpt.tokens.use.direct" in scopes && "resource.invoke" in scopes
}

class ChatGptAccount(private val keys: ProviderKeys, private val preferences: SharedPreferences, private val http: OkHttpClient) {
    sealed interface State {
        data object SignedOut : State
        data object SigningIn : State
        data class SignedIn(val email: String?) : State
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val refreshing = Mutex()
    private val random = SecureRandom()
    private val current = MutableStateFlow(resting())

    val state: StateFlow<State> = current

    suspend fun signIn(open: (Uri) -> Unit, returned: () -> Unit): Boolean {
        if (current.value == State.SigningIn) return false
        current.value = State.SigningIn
        try {
            val registration = stored()
            val verifier = token(64)
            val challenge = encoded(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
            val state = UUID.randomUUID().toString()
            val nonce = UUID.randomUUID().toString()
            val hostId = preferences.getString(HOST_ID_KEY, null) ?: "urn:uuid:${UUID.randomUUID().toString().lowercase()}".also { id ->
                preferences.edit { putString(HOST_ID_KEY, id) }
            }
            OxLog.info("chatgpt.signIn.started", "registration" to if (registration == null) "new" else "existing")
            val callback = awaitCallback { open(authorizeUrl(challenge, state, nonce, hostId, registration)) }
            returned()
            if (callback == null) {
                OxLog.info("chatgpt.signIn.cancelled")
                return false
            }
            if (callback.getQueryParameter("state") != state) throw ChatGptFailure("ChatGPT returned an invalid login callback")
            if (callback.getQueryParameter("error") != null) throw ChatGptFailure("ChatGPT login was declined. Allow OpenOx to use your ChatGPT plan to connect.")
            val returnedClient = callback.getQueryParameter("client_id")
            val code = callback.getQueryParameter("code")
            val clientId = returnedClient ?: registration?.clientId
            if (code.isNullOrEmpty() || clientId.isNullOrEmpty() || clientId == DYNAMIC_CLIENT ||
                (registration != null && returnedClient != null && returnedClient != registration.clientId)
            ) throw ChatGptFailure("ChatGPT did not return the expected OpenOx registration")
            val response = postToken(mapOf(
                "grant_type" to "authorization_code", "code" to code, "client_id" to clientId,
                "redirect_uri" to REDIRECT, "code_verifier" to verifier, "resource" to RESOURCE,
            ))
            val idToken = response.string("id_token") ?: throw ChatGptFailure("ChatGPT did not return an ID token")
            val identity = identity(idToken, clientId, nonce)
            if (registration != null && identity.first != registration.subject) {
                throw ChatGptFailure("ChatGPT returned a different account. The existing connection was not changed.")
            }
            val tokens = tokens(response, clientId, identity.first, identity.second, previous = null)
            store(tokens)
            if (!tokens.usable) throw ChatGptFailure("Allow OpenOx to use your ChatGPT plan, then sign in again.")
            OxLog.info("chatgpt.signIn.succeeded")
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            OxLog.warning("chatgpt.signIn.failed", "message" to error.message?.take(200))
            throw if (error is ChatGptFailure) error else ChatGptFailure("ChatGPT sign-in failed: ${error.message ?: error.javaClass.simpleName}")
        } finally {
            current.value = resting()
        }
    }

    suspend fun accessToken(): String = refreshing.withLock {
        val tokens = stored()?.takeIf { it.usable } ?: throw ChatGptFailure("Sign in to ChatGPT in Settings and allow OpenOx to use your plan")
        if (tokens.expiresAtMs > System.currentTimeMillis() + REFRESH_MARGIN_MS) return@withLock tokens.accessToken
        if (tokens.refreshToken.isEmpty()) {
            store(signedOut(tokens))
            throw ChatGptFailure("ChatGPT session expired. Sign in again.", expired = true)
        }
        try {
            val response = postToken(mapOf(
                "grant_type" to "refresh_token", "refresh_token" to tokens.refreshToken, "client_id" to tokens.clientId, "resource" to RESOURCE,
            ))
            response.string("id_token")?.let { idToken ->
                if (identity(idToken, tokens.clientId, nonce = null).first != tokens.subject) throw ChatGptFailure("ChatGPT refresh returned a different account", expired = true)
            }
            val refreshed = tokens(response, tokens.clientId, tokens.subject, tokens.email, tokens)
            store(refreshed)
            OxLog.info("chatgpt.refresh.succeeded")
            if (!refreshed.usable) throw ChatGptFailure("Allow OpenOx to use your ChatGPT plan, then sign in again.")
            refreshed.accessToken
        } catch (error: ChatGptFailure) {
            if (error.expired) store(signedOut(tokens))
            OxLog.warning("chatgpt.refresh.failed", "expired" to error.expired)
            throw error
        }
    }

    suspend fun signOut() {
        val tokens = stored() ?: return
        store(signedOut(tokens))
        OxLog.info("chatgpt.signOut")
        if (tokens.refreshToken.isEmpty()) return
        runCatching {
            val endpoint = document(CONFIGURATION).string("revocation_endpoint")?.takeIf { it.startsWith("https://auth.openai.com/") }
                ?: throw ChatGptFailure("ChatGPT did not publish a valid revocation endpoint")
            val form = FormBody.Builder().add("token", tokens.refreshToken).add("token_type_hint", "refresh_token").add("client_id", tokens.clientId).build()
            send(Request.Builder().url(endpoint).post(form).build()).use { check(it.code == 200) { "HTTP ${it.code}" } }
        }.onFailure { OxLog.warning("chatgpt.revoke.unconfirmed", "message" to it.message?.take(120)) }
    }

    private fun resting(): State = stored()?.takeIf { it.usable }?.let { State.SignedIn(it.email) } ?: State.SignedOut

    private fun stored(): ChatGptTokens? = keys.read(STORE_KEY)?.let { runCatching { json.decodeFromString(ChatGptTokens.serializer(), it) }.getOrNull() }

    private fun store(tokens: ChatGptTokens) {
        keys.write(STORE_KEY, json.encodeToString(ChatGptTokens.serializer(), tokens))
        if (current.value != State.SigningIn) current.value = resting()
    }

    private fun signedOut(tokens: ChatGptTokens) = tokens.copy(accessToken = "", refreshToken = "", idToken = "", scopes = emptySet())

    private fun authorizeUrl(challenge: String, state: String, nonce: String, hostId: String, registration: ChatGptTokens?): Uri {
        val parameters = sortedMapOf(
            "client_id" to (registration?.clientId ?: DYNAMIC_CLIENT), "ext_agent_host_id" to hostId, "response_type" to "code", "redirect_uri" to REDIRECT,
            "scope" to SCOPE, "resource" to RESOURCE, "state" to state, "nonce" to nonce, "code_challenge_method" to "S256", "code_challenge" to challenge,
        )
        if (registration != null) {
            if (registration.idToken.isNotEmpty()) parameters["id_token_hint"] = registration.idToken
            registration.email?.let { parameters["login_hint"] = it }
            if (registration.accessToken.isNotEmpty() && !registration.usable) parameters["prompt"] = "consent"
        } else {
            parameters["agent_name_hint"] = "OpenOx"
        }
        return AUTHORIZE.toUri().buildUpon().apply { parameters.forEach { (name, value) -> appendQueryParameter(name, value) } }.build()
    }

    private suspend fun awaitCallback(start: () -> Unit): Uri? = withContext(Dispatchers.IO) {
        val server = try {
            ServerSocket(CALLBACK_PORT, 4, InetAddress.getByName(CALLBACK_HOST))
        } catch (error: IOException) {
            throw ChatGptFailure("Another sign-in is already waiting on this device. Close it and try again.")
        }
        server.use {
            server.soTimeout = ACCEPT_MS
            withContext(Dispatchers.Main) { start() }
            withTimeoutOrNull(SIGN_IN_MS) {
                var callback: Uri? = null
                while (callback == null) {
                    ensureActive()
                    val connection = try {
                        server.accept()
                    } catch (_: SocketTimeoutException) {
                        continue
                    }
                    callback = connection.use { socket ->
                        socket.soTimeout = REQUEST_MS
                        val target = runCatching { socket.getInputStream().bufferedReader().readLine() }.getOrNull()?.split(' ')?.getOrNull(1)
                        val uri = target?.let { "http://$CALLBACK_HOST:$CALLBACK_PORT$it".toUri() }?.takeIf { it.path == CALLBACK_PATH }
                        val body = if (uri != null) DONE_PAGE else "Not found"
                        val head = "HTTP/1.1 ${if (uri != null) "200 OK" else "404 Not Found"}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.toByteArray().size}\r\nConnection: close\r\n\r\n"
                        runCatching { socket.getOutputStream().apply { write((head + body).toByteArray()) }.flush() }
                        uri
                    }
                }
                callback
            }
        }
    }

    private suspend fun send(request: Request): Response {
        var attempt = 1
        while (true) {
            try {
                return withContext(Dispatchers.IO) { http.newCall(request).execute() }
            } catch (error: IOException) {
                OxLog.warning("chatgpt.network.failed", "host" to request.url.host, "attempt" to attempt, "message" to error.message?.take(120))
                if (attempt == ATTEMPTS) throw ChatGptFailure("Could not reach ChatGPT: ${error.message ?: error.javaClass.simpleName}. Check the connection and try again.")
                delay(RETRY_MS * attempt)
                attempt += 1
            }
        }
    }

    private suspend fun postToken(form: Map<String, String>): JsonObject = withContext(Dispatchers.IO) {
        val body = FormBody.Builder().apply { form.forEach { (name, value) -> add(name, value) } }.build()
        send(Request.Builder().url(TOKEN).post(body).build()).use { response ->
            val parsed = runCatching { json.parseToJsonElement(response.body.string()) }.getOrNull() as? JsonObject
            if (!response.isSuccessful) {
                val code = parsed?.string("error") ?: (parsed?.get("error") as? JsonObject)?.string("code") ?: "unknown"
                val expired = form["grant_type"] == "refresh_token" && response.code in listOf(400, 401) && code in EXPIRED_CODES
                OxLog.warning("chatgpt.token.failed", "grant" to form["grant_type"], "status" to response.code, "expired" to expired)
                throw ChatGptFailure(if (expired) "ChatGPT session expired. Sign in again." else "ChatGPT token endpoint returned HTTP ${response.code}", expired)
            }
            parsed ?: throw ChatGptFailure("Malformed ChatGPT token response")
        }
    }

    private fun tokens(response: JsonObject, clientId: String, subject: String, email: String?, previous: ChatGptTokens?): ChatGptTokens {
        val access = response.string("access_token")
        val lifetime = (response["expires_in"] as? JsonPrimitive)?.doubleOrNull
        if (access.isNullOrEmpty() || lifetime == null || lifetime <= 0 || response.string("token_type")?.lowercase() != "bearer") {
            throw ChatGptFailure("ChatGPT returned invalid token credentials")
        }
        return ChatGptTokens(
            accessToken = access,
            refreshToken = response.string("refresh_token") ?: previous?.refreshToken.orEmpty(),
            idToken = response.string("id_token") ?: previous?.idToken.orEmpty(),
            clientId = clientId,
            subject = subject,
            email = email,
            scopes = response.string("scope")?.split(' ')?.filter { it.isNotEmpty() }?.toSet() ?: previous?.scopes.orEmpty(),
            expiresAtMs = System.currentTimeMillis() + (lifetime * 1000).toLong(),
        )
    }

    private suspend fun identity(idToken: String, clientId: String, nonce: String?): Pair<String, String?> {
        val parts = idToken.split('.')
        val header = parts.getOrNull(0)?.let(::decoded)?.let { runCatching { json.parseToJsonElement(String(it)) }.getOrNull() } as? JsonObject
        val claims = parts.getOrNull(1)?.let(::decoded)?.let { runCatching { json.parseToJsonElement(String(it)) }.getOrNull() } as? JsonObject
        val signature = parts.getOrNull(2)?.let(::decoded)
        val keyId = header?.string("kid")
        if (parts.size != 3 || claims == null || signature == null || keyId == null || header.string("alg") != "RS256") throw ChatGptFailure("ChatGPT returned an invalid ID token")
        val metadata = document(CONFIGURATION)
        val keysUrl = metadata.string("jwks_uri")?.takeIf { it.startsWith("https://auth.openai.com/") }
        if (metadata.string("issuer") != ISSUER || keysUrl == null) throw ChatGptFailure("ChatGPT identity configuration is invalid")
        val key = (document(keysUrl)["keys"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().firstOrNull {
            it.string("kid") == keyId && it.string("kty") == "RSA" && (it.string("use") ?: "sig") == "sig" && (it.string("alg") ?: "RS256") == "RS256"
        }
        val modulus = key?.string("n")?.let(::decoded)
        val exponent = key?.string("e")?.let(::decoded)
        if (modulus == null || exponent == null) throw ChatGptFailure("ChatGPT ID-token signing key is unavailable")
        val public = KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(BigInteger(1, modulus), BigInteger(1, exponent)))
        val verified = Signature.getInstance("SHA256withRSA").run {
            initVerify(public)
            update("${parts[0]}.${parts[1]}".toByteArray())
            verify(signature)
        }
        if (!verified) throw ChatGptFailure("ChatGPT ID-token signature could not be verified")
        val audiences = (claims["aud"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: listOfNotNull(claims.string("aud"))
        val expiry = (claims["exp"] as? JsonPrimitive)?.doubleOrNull
        val subject = claims.string("sub")
        if (claims.string("iss") != ISSUER || clientId !in audiences || (audiences.size != 1 && claims.string("azp") != clientId) ||
            expiry == null || expiry * 1000 <= System.currentTimeMillis() || subject.isNullOrEmpty() || (nonce != null && claims.string("nonce") != nonce)
        ) throw ChatGptFailure("ChatGPT ID-token identity, expiry, or nonce is invalid")
        return subject to claims.string("email")
    }

    private suspend fun document(url: String): JsonObject = withContext(Dispatchers.IO) {
        send(Request.Builder().url(url).build()).use { response ->
            (if (response.code == 200) runCatching { json.parseToJsonElement(response.body.string()) }.getOrNull() else null) as? JsonObject
                ?: throw ChatGptFailure("ChatGPT identity metadata is unavailable")
        }
    }

    private fun token(bytes: Int) = encoded(ByteArray(bytes).also(random::nextBytes))

    private fun encoded(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun decoded(text: String): ByteArray? = runCatching { Base64.decode(text, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP) }.getOrNull()

    companion object {
        const val PROVIDER_ID = "chatgpt"
        private const val STORE_KEY = "chatgpt:siwc"
        private const val HOST_ID_KEY = "chatgpt.hostId"
        private const val DYNAMIC_CLIENT = "dynamic_agent_client"
        private const val CALLBACK_HOST = "127.0.0.1"
        private const val CALLBACK_PORT = 1455
        private const val CALLBACK_PATH = "/auth/callback"
        private const val REDIRECT = "http://$CALLBACK_HOST:$CALLBACK_PORT$CALLBACK_PATH"
        private const val ISSUER = "https://auth.openai.com"
        private const val AUTHORIZE = "$ISSUER/api/accounts/authorize"
        private const val TOKEN = "$ISSUER/api/accounts/oauth/token"
        private const val CONFIGURATION = "$ISSUER/.well-known/openid-configuration"
        private const val RESOURCE = "https://api.openai.com/v1"
        private const val SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        private const val REFRESH_MARGIN_MS = 300_000L
        private const val SIGN_IN_MS = 600_000L
        private const val REQUEST_MS = 5_000
        private const val ACCEPT_MS = 500
        private const val ATTEMPTS = 4
        private const val RETRY_MS = 1_000L
        private const val DONE_PAGE = "<!doctype html><meta name=viewport content=\"width=device-width\"><title>Ox</title><body style=\"font-family:sans-serif;padding:24px\"><h3>You can return to Ox.</h3>"
        private val EXPIRED_CODES = setOf(
            "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_revoked", "refresh_token_invalidated", "refresh_token_reused",
        )
    }
}
