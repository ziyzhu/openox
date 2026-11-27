package ai.openox.ox.client.features.conversation

import ai.openox.ox.runtime.services.string
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

sealed interface TranscriptItem {
    val id: String

    data class UserText(override val id: String, val text: String, val attachments: List<FileRef>) : TranscriptItem
    data class UserSkill(override val id: String, val skill: String, val argument: String) : TranscriptItem
    data class AgentContent(override val id: String, val parts: List<AgentPart>) : TranscriptItem
    data class Thinking(override val id: String, val steps: List<ThinkingStep>, val seconds: Int?) : TranscriptItem {
        val completed: Boolean get() = seconds != null
    }
    data class Prompt(
        override val id: String,
        val prompt: String,
        val options: List<String>,
        val answer: String?,
        val resolution: String?,
    ) : TranscriptItem
    data class Compaction(override val id: String, val tokensBefore: Int?) : TranscriptItem
    data class Unsupported(override val id: String, val type: String) : TranscriptItem
}

sealed interface AgentPart {
    data class Text(val markdown: String) : AgentPart
    data class Progress(val text: String) : AgentPart
    data class File(val file: FileRef) : AgentPart
    data class Widget(val kind: String) : AgentPart
}

data class FileRef(val name: String, val path: String?, val attachmentId: String?)

sealed interface ThinkingStep {
    data class Reasoning(val text: String) : ThinkingStep
    data class Invocation(val name: String, val purpose: String, val outcome: InvocationOutcome) : ThinkingStep
}

sealed interface InvocationOutcome {
    data object Running : InvocationOutcome
    data object Succeeded : InvocationOutcome
    data class Failed(val message: String) : InvocationOutcome
}

object Transcript {
    fun items(blocks: List<JsonObject>, previous: List<JsonObject>, previousItems: List<TranscriptItem>): List<TranscriptItem> {
        val reusable = previous.size == previousItems.size
        return blocks.mapIndexed { index, block ->
            if (reusable && index < previous.size && previous[index] == block) previousItems[index] else item(block, index)
        }
    }

    private fun item(block: JsonObject, index: Int): TranscriptItem {
        val id = block.string("id") ?: "block-$index"
        val kind = block.obj("kind") ?: return TranscriptItem.Unsupported(id, "unknown")
        return when (val type = kind.string("type")) {
            "userText" -> TranscriptItem.UserText(id, kind.string("text").orEmpty(), files(kind.array("attachments")))
            "userSkill" -> {
                val invocation = kind.obj("skillInvocation")
                TranscriptItem.UserSkill(id, invocation?.obj("skill")?.string("name").orEmpty(), invocation?.string("argument").orEmpty())
            }
            "agentContent" -> TranscriptItem.AgentContent(id, kind.array("items").objects().map(::part))
            "thinking" -> {
                val trace = kind.obj("trace")
                val started = block.double("createdAt")
                val finished = trace?.double("completedAt")
                val seconds = finished?.let { end -> started?.let { Math.round(end - it).toInt().coerceAtLeast(1) } ?: 1 }
                TranscriptItem.Thinking(id, trace?.array("entries").objects().mapNotNull(::step), seconds)
            }
            "confirm" -> TranscriptItem.Prompt(
                id,
                kind.string("prompt").orEmpty(),
                kind.array("options").strings(),
                kind.string("answer"),
                kind.string("resolution"),
            )
            "contextCompaction" -> TranscriptItem.Compaction(id, kind.obj("contextCompaction")?.int("tokensBefore"))
            else -> TranscriptItem.Unsupported(id, type ?: "unknown")
        }
    }

    private fun part(item: JsonObject): AgentPart {
        item.string("text")?.let { return AgentPart.Text(it) }
        item.string("progress")?.let { return AgentPart.Progress(it) }
        item.obj("artifact")?.let { return AgentPart.File(fileRef(it, attachment = false)) }
        item.string("artifact")?.let { return AgentPart.File(FileRef(displayName(it), path = it, attachmentId = null)) }
        return AgentPart.Widget(item.keys.firstOrNull() ?: "content")
    }

    private fun step(entry: JsonObject): ThinkingStep? = when (entry.string("kind")) {
        "reasoning" -> entry.obj("reasoning")?.string("text")?.let(ThinkingStep::Reasoning)
        "invocation" -> entry.obj("invocation")?.let { invocation ->
            ThinkingStep.Invocation(
                invocation.string("name").orEmpty(),
                invocation.string("purpose").orEmpty(),
                outcome(invocation.obj("outcome")),
            )
        }
        else -> null
    }

    private fun outcome(value: JsonObject?): InvocationOutcome = when {
        value == null || "running" in value -> InvocationOutcome.Running
        "failed" in value -> InvocationOutcome.Failed(value.obj("failed")?.string("_0").orEmpty())
        else -> InvocationOutcome.Succeeded
    }

    private fun files(values: JsonArray?): List<FileRef> = values.orEmpty().mapNotNull { element ->
        when (element) {
            is JsonObject -> fileRef(element, attachment = true)
            is JsonPrimitive -> element.contentOrNull?.let { FileRef(displayName(it), path = null, attachmentId = it) }
            else -> null
        }
    }

    private fun displayName(stored: String): String {
        val name = stored.substringAfterLast('/')
        return if (GENERATED.matches(name)) "Attachment.${name.substringAfterLast('.', "file")}" else name
    }

    private val GENERATED = Regex("""file-[0-9A-Fa-f-]{36}(\.[A-Za-z0-9]+)?""")

    private fun fileRef(file: JsonObject, attachment: Boolean): FileRef {
        val name = file.string("fileURL")?.substringAfterLast('/')?.takeIf { it.isNotEmpty() } ?: file.string("fileName").orEmpty()
        val path = file.string("virtualPath")
        return FileRef(name, path = path, attachmentId = if (attachment || path == null) file.string("fileName") else null)
    }

    private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun JsonObject.double(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()
    private fun JsonObject.int(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.toInt()
    private fun JsonObject.obj(key: String) = this[key] as? JsonObject
    private fun JsonObject.array(key: String) = this[key] as? JsonArray
    private fun JsonArray?.objects(): List<JsonObject> = this?.filterIsInstance<JsonObject>().orEmpty()
    private fun JsonArray?.strings(): List<String> =
        this?.mapNotNull { element: JsonElement -> (element as? JsonPrimitive)?.contentOrNull }.orEmpty()
}
