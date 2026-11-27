package ai.openox.ox.remote

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable
data class ProfileDescription(
    val implementation: Implementation,
    val protocols: Map<String, List<Int>>,
    val methods: List<String>,
    val device: Device? = null,
    val profile: Profile? = null,
) {
    @Serializable
    data class Device(val name: String)

    @Serializable
    data class Profile(val id: String, val name: String)

    @Serializable
    data class Implementation(val name: String, val version: String, val build: String)
}

@Serializable
data class ConversationRow(
    val id: String,
    val title: String,
    val model: String? = null,
    val createdAt: String,
    val lastActivity: String? = null,
    val active: Boolean,
    val pinned: Boolean = false,
    val scheduled: Boolean = false,
    val status: String = "read",
    val parentId: String? = null,
) {
    val unread: Boolean get() = status == "unread"
    val running: Boolean get() = status == "thinking" || status == "streaming"
    val stopped: Boolean get() = status == "stopped"
    val awaiting: String? get() = status.removePrefix("awaiting.").takeIf { status.startsWith("awaiting.") }
}

@Serializable
data class ListConversationsResult(val conversations: List<ConversationRow>)

@Serializable
data class NewConversationResult(val conversationId: String, val temporary: Boolean, val model: String)

@Serializable
data class PendingPrompt(
    val id: String,
    val prompt: String,
    val options: List<String>,
    val allowsCustomAnswer: Boolean,
    val requiresApp: Boolean,
)

@Serializable
data class ConversationSnapshot(
    val id: String,
    val model: JsonObject = JsonObject(emptyMap()),
    val blocks: List<JsonObject>,
    val isBusy: Boolean = false,
    val pendingPrompt: PendingPrompt? = null,
)

@Serializable
data class GetConversationResult(val data: ConversationSnapshot? = null)

@Serializable
data class TurnEnding(val kind: String, val message: String? = null)

@Serializable
data class FollowIntent(val label: String, val message: String)

@Serializable
data class QueuedMessage(val id: String, val text: String, val attachments: List<String> = emptyList())

@Serializable
data class ConversationView(
    val id: String,
    val title: String,
    val providerId: String,
    val model: JsonObject = JsonObject(emptyMap()),
    val temporary: Boolean = false,
    val blocks: List<JsonObject>,
    val isBusy: Boolean = false,
    val status: String = "read",
    val pendingPrompt: PendingPrompt? = null,
    val turnEnding: TurnEnding? = null,
    val followIntents: List<FollowIntent> = emptyList(),
    val queued: List<QueuedMessage> = emptyList(),
    val services: List<String> = emptyList(),
    val parentId: String? = null,
    val parentTitle: String? = null,
)

@Serializable
data class ConversationViewResult(val data: ConversationView)

@Serializable
data class ConversationIDResult(val conversationId: String)

@Serializable
enum class SendOutcome {
    @SerialName("queued") Queued,
    @SerialName("completed") Completed,
    @SerialName("failed") Failed,
    @SerialName("cancelled") Cancelled,
    @SerialName("needsAttention") NeedsAttention,
}

@Serializable
data class SendConversationResult(
    val conversationId: String,
    val outcome: SendOutcome,
    val text: String? = null,
    val error: String? = null,
)

@Serializable
data class StopConversationResult(val conversationId: String, val wasRunning: Boolean)

@Serializable
data class RespondConversationResult(val conversationId: String, val promptId: String)

@Serializable
data class ModelRow(val id: String, val displayName: String, val reasoning: Boolean = false, val reasoningEfforts: List<String> = emptyList())

@Serializable
data class ProviderRow(val id: String, val displayName: String, val models: List<ModelRow>)

@Serializable
data class DefaultModel(val providerId: String, val modelId: String)

@Serializable
data class ListProvidersResult(val region: String, val providers: List<ProviderRow>, val defaultModel: DefaultModel? = null)

@Serializable
data class SkillRow(val name: String, val description: String, val services: List<String> = emptyList())

@Serializable
data class ListSkillsResult(val skills: List<SkillRow>)

@Serializable
data class ProfileRow(val id: String, val name: String, val location: String, val version: String, val active: Boolean)

@Serializable
data class ProfileResult(val profile: ProfileRow, val memory: String? = null, val soul: String? = null)

@Serializable
data class FolderGrantRow(val id: String, val name: String)

@Serializable
data class ListFolderGrantsResult(val folders: List<FolderGrantRow>, val unassignedFolders: List<FolderGrantRow> = emptyList())

@Serializable
data class ServiceRow(
    val domain: String,
    val title: String,
    val phase: String,
    val signIn: String,
    val activeInvocations: Int = 0,
    val queuedInvocations: Int = 0,
    val pageCount: Int = 0,
    val favicon: String? = null,
)

@Serializable
data class ListServicesResult(val services: List<ServiceRow>)

@Serializable
data class RepositoryRow(val id: String, val name: String, val provenance: String, val enabled: Boolean, val state: String, val error: String? = null)

@Serializable
data class ListRepositoriesResult(val repositories: List<RepositoryRow>)

@Serializable
data class LogRow(val seq: Long, val time: String, val level: String, val category: String, val message: String)

@Serializable
data class GetLogsResult(val logs: List<LogRow>, val nextCursor: String? = null, val hasMore: Boolean = false)

@Serializable
data class DownloadFileResult(val transferId: String, val offset: Long, val size: Long, val data: String)

@Serializable
class EmptyResult
