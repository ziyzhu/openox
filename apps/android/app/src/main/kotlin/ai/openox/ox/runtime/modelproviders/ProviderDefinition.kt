package ai.openox.ox.runtime.modelproviders

import ai.openox.ox.runtime.agent.llm.providers.chatgpt.ChatGptAccount
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
enum class WireProtocol {
    @SerialName("openai-chat-completions") ChatCompletions,
    @SerialName("openai-responses") Responses,
    @SerialName("anthropic-messages") AnthropicMessages,
    @SerialName("gemini-generate-content") Gemini,
    @SerialName("web") Web,
}

@Serializable
enum class AuthKind {
    @SerialName("none") None,
    @SerialName("bearer") Bearer,
    @SerialName("api-key") ApiKey,
    @SerialName("oauth") OAuth,
    @SerialName("custom") Custom,
}

@Serializable
data class ProviderAuth(val kind: AuthKind, val optional: Boolean = false, val header: String? = null, val adapter: String? = null)

@Serializable
data class ProviderOptions(
    val headers: Map<String, String> = emptyMap(),
    val extraBody: Map<String, JsonElement> = emptyMap(),
    val maxTokensField: String? = null,
    val reasoningFormat: String? = null,
    val reasoningEffort: String? = null,
    val version: String? = null,
    val beta: List<String> = emptyList(),
    val sessionHeader: String? = null,
)

@Serializable
data class ModelOptions(val replayReasoning: Boolean = false, val adaptiveThinking: Boolean = false, val serviceTier: String? = null)

@Serializable
data class ModelDefinition(
    val id: String,
    val name: String,
    val wireID: String? = null,
    val contextTokens: Int = 32_768,
    val outputTokens: Int = 4_096,
    val reasoningEfforts: List<String> = emptyList(),
    val options: ModelOptions = ModelOptions(),
) {
    val wire: String get() = wireID ?: id
}

@Serializable
data class ProviderDefinition(
    val id: String,
    val name: String,
    val url: String,
    val api: WireProtocol,
    val auth: ProviderAuth,
    val options: ProviderOptions = ProviderOptions(),
    val models: List<ModelDefinition> = emptyList(),
) {
    val needsKey: Boolean get() = auth.kind != AuthKind.None && !auth.optional
}

@Serializable
data class ProviderOffer(val summary: String? = null, val priority: Int = Int.MAX_VALUE)

@Serializable
data class ProviderPresentation(
    val website: String? = null,
    val authNotice: String? = null,
    val iconURL: String? = null,
    val regions: List<String> = emptyList(),
    val offer: ProviderOffer? = null,
)

@Serializable
data class BundledProvider(val definition: ProviderDefinition, val presentation: ProviderPresentation = ProviderPresentation())

@Serializable
data class CustomProvider(val id: String, val name: String, val url: String)

data class ProviderEntry(
    val definition: ProviderDefinition,
    val website: String?,
    val notice: String?,
    val custom: Boolean,
    val hasKey: Boolean,
    val iconUrl: String? = null,
    val offer: ProviderOffer? = null,
) {
    val ready: Boolean get() = hasKey || !definition.needsKey
    val account: Boolean get() = definition.id == ChatGptAccount.PROVIDER_ID
}
