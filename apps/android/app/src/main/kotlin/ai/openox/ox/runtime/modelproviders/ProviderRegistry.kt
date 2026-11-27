package ai.openox.ox.runtime.modelproviders

import ai.openox.ox.diagnostics.OxLog
import ai.openox.ox.runtime.agent.llm.providers.chatgpt.ChatGptAccount
import ai.openox.ox.runtime.services.ServiceIcons
import ai.openox.ox.runtime.services.string
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import java.net.URI
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

class ProviderKeys(context: Context) {
    private val preferences = context.getSharedPreferences("provider-keys", Context.MODE_PRIVATE)

    fun has(providerId: String): Boolean = preferences.contains(providerId)

    fun read(providerId: String): String? {
        val stored = preferences.getString(providerId, null)?.split(':') ?: return null
        if (stored.size != 2) return null
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, Base64.decode(stored[0], Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(stored[1], Base64.NO_WRAP)), Charsets.UTF_8)
        }.onFailure { OxLog.error("providerKeys.read.failed", "provider" to providerId, "message" to it.message) }.getOrNull()
    }

    fun write(providerId: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        preferences.edit {
            putString(providerId, Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(sealed, Base64.NO_WRAP))
        }
    }

    fun remove(providerId: String) = preferences.edit { remove(providerId) }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "ox.provider-keys"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}

class ModelProviders private constructor(context: Context) {
    private val application = context.applicationContext
    private val preferences = application.getSharedPreferences("providers", Context.MODE_PRIVATE)
    private val keys = ProviderKeys(application)
    private val json = Json { ignoreUnknownKeys = true }
    private val discovered = mutableMapOf<String, List<ModelDefinition>>()
    private val bundled: List<BundledProvider> by lazy {
        val text = application.assets.open("agent/providers.json").bufferedReader().use { it.readText() }
        json.decodeFromString(ListSerializer(BundledProvider.serializer()), text)
            .filter { it.definition.api in SUPPORTED_PROTOCOLS && (it.definition.auth.kind in SUPPORTED_AUTH || it.definition.auth.adapter == ChatGptAccount.PROVIDER_ID) }
            .sortedByDescending { it.definition.id == ChatGptAccount.PROVIDER_ID }
    }

    val http: OkHttpClient = OkHttpClient.Builder().readTimeout(STREAM_IDLE_SECONDS, TimeUnit.SECONDS).build()

    val chatGpt = ChatGptAccount(keys, preferences, http)

    private val _entries = MutableStateFlow<List<ProviderEntry>>(emptyList())
    val entries: StateFlow<List<ProviderEntry>> = _entries.asStateFlow()

    var endpointOverrides: Map<String, String> = emptyMap()

    val icons = ServiceIcons(java.io.File(application.cacheDir, "provider-icons"), http)

    var region: String
        get() = preferences.getString(REGION_KEY, null)?.takeIf { it in REGIONS } ?: REGIONS.first()
        set(value) {
            preferences.edit { putString(REGION_KEY, value) }
            OxLog.info("providers.region", "region" to value)
            refresh()
        }

    var defaultModel: Pair<String, String>?
        get() = preferences.getString(DEFAULT_PROVIDER_KEY, null)?.let { provider -> preferences.getString(DEFAULT_MODEL_KEY, null)?.let { provider to it } }
        set(value) {
            preferences.edit {
                putString(DEFAULT_PROVIDER_KEY, value?.first)
                putString(DEFAULT_MODEL_KEY, value?.second)
            }
            OxLog.info("providers.default", "provider" to value?.first, "model" to value?.second)
        }

    fun refresh() {
        val region = region
        val catalog = bundled.filter { region in it.presentation.regions }.map {
            val signedIn = it.definition.id == ChatGptAccount.PROVIDER_ID && chatGpt.state.value is ChatGptAccount.State.SignedIn
            ProviderEntry(
                resolved(it.definition), it.presentation.website, it.presentation.authNotice, custom = false, hasKey = signedIn || keys.has(it.definition.id),
                iconUrl = it.presentation.iconURL, offer = it.presentation.offer,
            )
        }
        val custom = customProviders().map { provider ->
            val definition = ProviderDefinition(
                provider.id, provider.name, provider.url, WireProtocol.ChatCompletions, ProviderAuth(AuthKind.Bearer, optional = true),
                models = synchronized(discovered) { discovered[provider.id].orEmpty() },
            )
            ProviderEntry(definition, website = null, notice = null, custom = true, hasKey = keys.has(provider.id))
        }
        _entries.value = custom + catalog
    }

    fun entry(providerId: String): ProviderEntry? = _entries.value.firstOrNull { it.definition.id == providerId }

    suspend fun credential(providerId: String): String? = if (providerId == ChatGptAccount.PROVIDER_ID) chatGpt.accessToken() else keys.read(providerId)

    fun setKey(providerId: String, value: String) {
        if (value.isBlank()) keys.remove(providerId) else keys.write(providerId, value.trim())
        OxLog.info("providers.key", "provider" to providerId, "present" to value.isNotBlank())
        refresh()
    }

    fun normalized(address: String): Result<String> = runCatching {
        val uri = URI(address.trim())
        require(uri.scheme == "https" || uri.scheme == "http") { "Enter an http:// or https:// address" }
        require(!uri.host.isNullOrEmpty()) { "The address needs a host name" }
        val trimmed = address.trim().trimEnd('/')
        if (uri.path.isNullOrEmpty() || uri.path == "/") "$trimmed/v1" else trimmed
    }

    suspend fun models(address: String, key: String?): Result<List<ModelDefinition>> = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder().url("$address/models").apply { key?.takeIf { it.isNotBlank() }?.let { header("Authorization", "Bearer ${it.trim()}") } }.build()
            http.newCall(request).execute().use { response ->
                check(response.isSuccessful) { "The server answered HTTP ${response.code}" }
                val body = json.parseToJsonElement(response.body.string()) as? JsonObject
                val found = (body?.get("data") as? JsonArray).orEmpty().mapNotNull { ((it as? JsonObject)?.get("id") as? JsonPrimitive)?.contentOrNull }.map { ModelDefinition(it, it) }
                check(found.isNotEmpty()) { "The server listed no models" }
                found
            }
        }.onFailure { OxLog.warning("providers.models.failed", "message" to it.message?.take(120)) }
    }

    fun addCustom(name: String, address: String, key: String?, models: List<ModelDefinition>): CustomProvider {
        val provider = CustomProvider("custom:${UUID.randomUUID().toString().lowercase()}", name.trim(), address)
        saveCustom(customProviders() + provider)
        if (!key.isNullOrBlank()) keys.write(provider.id, key.trim())
        synchronized(discovered) { discovered[provider.id] = models }
        OxLog.info("providers.custom.added", "provider" to provider.id, "models" to models.size)
        refresh()
        return provider
    }

    fun removeCustom(providerId: String) {
        saveCustom(customProviders().filterNot { it.id == providerId })
        keys.remove(providerId)
        synchronized(discovered) { discovered.remove(providerId) }
        OxLog.info("providers.custom.removed", "provider" to providerId)
        refresh()
    }

    suspend fun discover() {
        customProviders().forEach { provider ->
            val models = withContext(Dispatchers.IO) {
                runCatching {
                    val request = Request.Builder().url("${provider.url}/models").apply {
                        keys.read(provider.id)?.let { header("Authorization", "Bearer $it") }
                    }.build()
                    http.newCall(request).execute().use { response ->
                        check(response.isSuccessful) { "HTTP ${response.code}" }
                        val body = json.parseToJsonElement(response.body.string()) as JsonObject
                        (body["data"] as? JsonArray).orEmpty().mapNotNull { ((it as? JsonObject)?.get("id") as? JsonPrimitive)?.contentOrNull }
                            .map { ModelDefinition(it, it) }
                    }
                }.onFailure { OxLog.warning("providers.discover.failed", "provider" to provider.id, "message" to it.message) }.getOrNull()
            } ?: return@forEach
            synchronized(discovered) { discovered[provider.id] = models }
        }
        refresh()
    }

    private fun resolved(definition: ProviderDefinition): ProviderDefinition =
        endpointOverrides[definition.id]?.let { definition.copy(url = it) } ?: definition

    private fun customProviders(): List<CustomProvider> =
        preferences.getString(CUSTOM_KEY, null)?.let { runCatching { json.decodeFromString(ListSerializer(CustomProvider.serializer()), it) }.getOrNull() }.orEmpty()

    private fun saveCustom(providers: List<CustomProvider>) =
        preferences.edit { putString(CUSTOM_KEY, json.encodeToString(ListSerializer(CustomProvider.serializer()), providers)) }

    companion object {
        private const val CUSTOM_KEY = "custom"
        private const val REGION_KEY = "region"
        val REGIONS = listOf("global", "china")
        private const val DEFAULT_PROVIDER_KEY = "defaultProvider"
        private const val DEFAULT_MODEL_KEY = "defaultModel"
        private const val STREAM_IDLE_SECONDS = 120L
        private val SUPPORTED_PROTOCOLS = setOf(WireProtocol.ChatCompletions, WireProtocol.Responses, WireProtocol.AnthropicMessages)
        private val SUPPORTED_AUTH = setOf(AuthKind.Bearer, AuthKind.ApiKey)

        @Volatile
        private var instance: ModelProviders? = null

        fun get(context: Context): ModelProviders = instance ?: synchronized(this) {
            instance ?: ModelProviders(context).also {
                it.refresh()
                instance = it
            }
        }
    }
}
