package ai.openox.ox.remote

import ai.openox.ox.platform.models.HostEndpoint
import android.util.Base64
import java.io.ByteArrayOutputStream
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

class Upload(val name: String, val bytes: ByteArray)

class HostClient(val endpoint: HostEndpoint, private val connection: HostLink) {
    private val versionLock = Mutex()
    private val downloadLock = Mutex()
    private var checkedGeneration: Int? = null
    private var methods: Set<String> = emptySet()

    fun supports(method: String): Boolean = method in methods

    suspend fun describe(): ProfileDescription = versionLock.withLock { describeAndCheck() }

    suspend fun listConversations(): List<ConversationRow> =
        call("conversations.list", ListConversationsResult.serializer()).conversations

    suspend fun newConversation(providerId: String?, modelId: String?, temporary: Boolean, effort: String? = null): NewConversationResult =
        call("conversations.new", NewConversationResult.serializer(), buildJsonObject {
            if (temporary) put("temporary", true)
            if (providerId != null && modelId != null) {
                put("providerId", providerId)
                put("modelId", modelId)
                if (effort != null && supports("conversations.setModel")) put("reasoningEffort", effort)
            }
        })

    suspend fun setModel(id: String, providerId: String, modelId: String, effort: String?) =
        call("conversations.setModel", EmptyResult.serializer(), conversation(id) {
            put("providerId", providerId)
            put("modelId", modelId)
            if (effort != null) put("reasoningEffort", effort)
        })

    suspend fun openConversation(id: String): ConversationSnapshot =
        snapshot(call("conversations.open", GetConversationResult.serializer(), conversation(id)))

    suspend fun getConversation(id: String): ConversationSnapshot =
        snapshot(call("conversations.get", GetConversationResult.serializer(), conversation(id)))

    suspend fun viewConversation(id: String): ConversationView =
        call("conversations.view", ConversationViewResult.serializer(), conversation(id)).data

    suspend fun send(id: String, text: String, uploads: List<Upload> = emptyList(), skill: String? = null): SendConversationResult =
        call("conversations.send", SendConversationResult.serializer(), buildJsonObject {
            put("conversationId", id)
            put("text", text)
            put("wait", false)
            if (uploads.isNotEmpty()) putJsonArray("attachments") {
                uploads.forEach { upload ->
                    addJsonObject {
                        put("name", upload.name)
                        put("data", Base64.encodeToString(upload.bytes, Base64.NO_WRAP))
                    }
                }
            }
            if (skill != null) put("skill", skill)
        }, timeout = if (uploads.isEmpty()) 20.seconds else 120.seconds)

    suspend fun stop(id: String): StopConversationResult =
        call("conversations.stop", StopConversationResult.serializer(), conversation(id))

    suspend fun respond(id: String, promptId: String, answer: String): RespondConversationResult =
        call("conversations.respond", RespondConversationResult.serializer(), buildJsonObject {
            put("conversationId", id)
            put("promptId", promptId)
            put("answer", answer)
        })

    suspend fun rename(id: String, title: String) =
        call("conversations.rename", EmptyResult.serializer(), conversation(id) { put("title", title) })

    suspend fun pin(id: String, pinned: Boolean) =
        call("conversations.pin", EmptyResult.serializer(), conversation(id) { put("pinned", pinned) })

    suspend fun delete(id: String) = call("conversations.delete", EmptyResult.serializer(), conversation(id))

    suspend fun branch(id: String, blockId: String): String =
        call("conversations.branch", ConversationIDResult.serializer(), conversation(id) { put("blockId", blockId) }, 60.seconds).conversationId

    suspend fun retry(id: String, blockId: String): String =
        call("conversations.retry", ConversationIDResult.serializer(), conversation(id) { put("blockId", blockId) }, 60.seconds).conversationId

    suspend fun edit(id: String, blockId: String, text: String): String =
        call("conversations.edit", ConversationIDResult.serializer(), conversation(id) {
            put("blockId", blockId)
            put("text", text)
        }, 60.seconds).conversationId

    suspend fun retryFailed(id: String): String =
        call("conversations.retryFailed", ConversationIDResult.serializer(), conversation(id)).conversationId

    suspend fun cancelQueued(id: String, blockId: String) =
        call("conversations.cancelQueued", EmptyResult.serializer(), conversation(id) { put("blockId", blockId) })

    suspend fun setServices(id: String, domains: List<String>) =
        call("conversations.setServices", EmptyResult.serializer(), conversation(id) {
            putJsonArray("domains") { domains.forEach { add(it) } }
        })

    suspend fun listProviders(): ListProvidersResult = call("providers.list", ListProvidersResult.serializer())

    suspend fun listSkills(): List<SkillRow> = call("skills.list", ListSkillsResult.serializer()).skills

    suspend fun listServices(): List<ServiceRow> = call("services.list", ListServicesResult.serializer(), timeout = 90.seconds).services

    suspend fun reloadService(domain: String) =
        call("services.reload", JsonObject.serializer(), buildJsonObject { put("domain", domain) }, 60.seconds)

    suspend fun refreshServiceAuth(domain: String) =
        call("services.refreshAuth", JsonObject.serializer(), buildJsonObject { put("domain", domain) }, 60.seconds)

    suspend fun inspectProfile(): ProfileResult = call("profile.inspect", ProfileResult.serializer())

    suspend fun updateProfile(name: String? = null, memory: String? = null, soul: String? = null): ProfileResult =
        call("profile.update", ProfileResult.serializer(), buildJsonObject {
            if (name != null) put("name", name)
            if (memory != null) put("memory", memory)
            if (soul != null) put("soul", soul)
        })

    suspend fun listFolders(): ListFolderGrantsResult = call("files.list", ListFolderGrantsResult.serializer())

    suspend fun unmountFolder(grantId: String) =
        call("files.unmount", EmptyResult.serializer(), buildJsonObject { put("grantId", grantId) })

    suspend fun listRepositories(): List<RepositoryRow> = call("repositories.list", ListRepositoriesResult.serializer()).repositories

    suspend fun logs(limit: Int, cursor: String?, level: String?, query: String?): GetLogsResult =
        call("logs.list", GetLogsResult.serializer(), buildJsonObject {
            put("limit", limit)
            if (cursor != null) put("cursor", cursor)
            if (level != null) put("level", level)
            if (query != null) put("query", query)
        })

    suspend fun download(conversationId: String, path: String?, attachmentId: String?): ByteArray = downloadLock.withLock {
        val output = ByteArrayOutputStream()
        var chunk = call("files.download", DownloadFileResult.serializer(), buildJsonObject {
            put("conversationId", conversationId)
            if (path != null) put("path", path) else put("attachmentId", attachmentId)
        }, 60.seconds)
        output.write(Base64.decode(chunk.data, Base64.DEFAULT))
        while (output.size() < chunk.size) {
            chunk = call("files.download", DownloadFileResult.serializer(), buildJsonObject { put("transferId", chunk.transferId) }, 60.seconds)
            output.write(Base64.decode(chunk.data, Base64.DEFAULT))
        }
        output.toByteArray()
    }

    fun close() = connection.close()

    private suspend fun <T> call(
        method: String,
        serializer: KSerializer<T>,
        params: JsonObject = JsonObject(emptyMap()),
        timeout: Duration = 20.seconds,
    ): T {
        if (method != "profile.describe") checkVersion()
        val result = connection.request(method, params, timeout)
        return try {
            json.decodeFromJsonElement(serializer, result)
        } catch (error: SerializationException) {
            throw HostError.Invalid("Host returned an invalid $method result: ${error.message}")
        }
    }

    private suspend fun checkVersion() = versionLock.withLock {
        if (checkedGeneration != connection.generation) describeAndCheck()
    }

    private suspend fun describeAndCheck(): ProfileDescription {
        val description = call("profile.describe", ProfileDescription.serializer())
        val revisions = description.protocols["rpc"].orEmpty()
        if (RPC_VERSION !in revisions) throw HostError.Unsupported(revisions)
        checkedGeneration = connection.generation
        methods = description.methods.toSet()
        return description
    }

    private fun conversation(id: String, extra: JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("conversationId", id)
        extra()
    }

    private fun snapshot(result: GetConversationResult) =
        result.data ?: throw HostError.Invalid("Host did not return the conversation")

    companion object {
        const val RPC_VERSION = 5

        val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
        }
    }
}
