package ai.openox.ox.runtime.files

import ai.openox.ox.runtime.durable.AgentRuntimeException
import ai.openox.ox.runtime.services.string
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class ProfileFiles(private val files: File, private val temporary: File, private val bundle: File, private val local: File) {
    private class Capability(val conversation: Int, val operation: String)

    private class Refusal(val code: String, message: String) : Exception(message)

    private class Location(val file: File, val writable: Boolean)

    private val capabilities = ConcurrentHashMap<String, Capability>()

    val mounts: JsonArray = buildJsonArray {
        addJsonObject {
            put("path", FILES)
            put("access", "readWrite")
        }
        addJsonObject {
            put("path", TEMPORARY)
            put("access", "readOnly")
        }
        addJsonObject {
            put("path", SKILLS)
            put("access", "readOnly")
        }
        addJsonObject {
            put("path", REPOSITORIES)
            put("access", "readWrite")
        }
    }

    init {
        files.mkdirs()
        temporary.deleteRecursively()
        local.mkdirs()
        File(local, "repository.json").takeUnless { it.exists() }?.writeText("{\n  \"version\": 3,\n  \"name\": \"Local\",\n  \"services\": [],\n  \"skills\": []\n}\n")
    }

    fun rooted(path: JsonElement): JsonElement {
        val text = (path as? JsonPrimitive)?.takeIf { it.isString }?.content?.trimStart('/')?.removePrefix("./") ?: return path
        return JsonPrimitive(if (text.isEmpty() || text.substringBefore('/') in ROOTS) text else "$FILES/$text")
    }

    fun grant(conversation: Int, operation: String): String =
        UUID.randomUUID().toString().also { capabilities[it] = Capability(conversation, operation) }

    fun revoke(token: String) {
        capabilities.remove(token)
    }

    fun forget(conversation: Int) {
        scratch(conversation).deleteRecursively()
    }

    suspend fun keep(conversation: Int, output: String): String = withContext(Dispatchers.IO) {
        val name = "output-${UUID.randomUUID().toString().take(8)}.txt"
        scratch(conversation).apply { mkdirs() }.resolve(name).writeText(output)
        "$TEMPORARY/$name"
    }

    suspend fun perform(params: JsonObject): JsonElement = withContext(Dispatchers.IO) {
        val capability = params.string("capability")?.let(capabilities::get) ?: throw AgentRuntimeException("Filesystem backend capability is expired or outside its scope")
        val operation = params.string("op") ?: throw AgentRuntimeException("Missing filesystem operation")
        val path = params.string("path") ?: throw AgentRuntimeException("Missing filesystem path")
        try {
            buildJsonObject { put("value", perform(capability, operation, path, params)) }
        } catch (refusal: Refusal) {
            buildJsonObject {
                putJsonObject("error") {
                    put("code", refusal.code)
                    put("message", refusal.message)
                }
            }
        }
    }

    private fun perform(capability: Capability, operation: String, path: String, params: JsonObject): JsonElement {
        if (path == REPOSITORIES) return when (operation) {
            "info" -> item(path, local.parentFile ?: local)
            "list" -> buildJsonArray {
                add(item("$REPOSITORIES/$BUILTIN", bundle))
                add(item("$REPOSITORIES/$LOCAL", local))
            }
            else -> throw Refusal("permission_denied", "This location is read-only")
        }
        val location = locate(capability, path)
        val target = location.file
        if (operation in MUTATIONS) {
            if (!location.writable) throw Refusal("permission_denied", "This location is read-only")
            val allowed = if (operation == "write") capability.operation in WRITERS else capability.operation == operation
            if (!allowed) throw AgentRuntimeException("Filesystem capability cannot $operation")
        }
        return when (operation) {
            "info" -> if (target.exists()) item(path, target) else throw Refusal("not_found", "File not found")
            "list" -> {
                if (!target.exists()) throw Refusal("not_found", "Directory not found")
                val children = target.listFiles() ?: throw Refusal("not_directory", "Not a directory")
                if (children.size > MAX_ENTRIES) throw Refusal("invalid", "Directory exceeds entry limit")
                buildJsonArray { children.sortedBy { it.name }.forEach { add(item("$path/${it.name}", it)) } }
            }
            "read" -> read(target)
            "write" -> {
                if (target.isDirectory) throw Refusal("is_directory", "Path is a directory")
                val bytes = params.string("base64")?.let { encoded ->
                    runCatching { Base64.getDecoder().decode(encoded) }.getOrElse { throw Refusal("invalid", "Invalid Base64 content") }
                } ?: run {
                    val content = params.string("content") ?: throw AgentRuntimeException("Missing file content")
                    val expected = params.string("expected")
                    if (expected != null && target.isFile && target.readText() != expected) throw Refusal("invalid", "File changed since it was read; read it again before editing")
                    content.toByteArray()
                }
                if (bytes.size > MAX_FILE_BYTES) throw Refusal("invalid", "File exceeds the 32 MiB limit")
                target.parentFile?.mkdirs()
                val staged = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
                try {
                    staged.writeBytes(bytes)
                    Files.move(staged.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                } finally {
                    staged.delete()
                }
                JsonNull
            }
            "mkdir" -> {
                if (target.isFile) throw Refusal("invalid", "A file already exists at this path")
                val recursive = (params["recursive"] as? JsonPrimitive)?.booleanOrNull == true
                if (!recursive && target.parentFile?.isDirectory != true) throw Refusal("not_found", "Parent directory not found")
                if (!target.isDirectory && !target.mkdirs()) throw Refusal("unknown", "Could not create the directory")
                JsonNull
            }
            "move", "copy" -> {
                val to = params.string("to") ?: throw AgentRuntimeException("Missing transfer destination")
                val arrival = locate(capability, to)
                if (!arrival.writable) throw Refusal("permission_denied", "This location is read-only")
                val destination = arrival.file
                if (!target.exists()) throw Refusal("not_found", "File not found")
                if (destination.exists()) throw Refusal("invalid", "Destination already exists")
                if (destination.canonicalPath.startsWith(target.canonicalPath + File.separator)) throw Refusal("invalid", "Destination is inside the source")
                destination.parentFile?.mkdirs()
                if (operation == "move") Files.move(target.toPath(), destination.toPath()) else target.copyRecursively(destination)
                JsonNull
            }
            "rm" -> throw Refusal("permission_denied", "Deleting files is not available on this device yet")
            "activate" -> JsonNull
            else -> throw AgentRuntimeException("Unsupported filesystem operation $operation")
        }
    }

    private fun read(target: File): JsonElement {
        if (!target.exists()) throw Refusal("not_found", "File not found")
        if (target.isDirectory) throw Refusal("is_directory", "Path is a directory")
        val oversized = target.length() > MAX_FILE_BYTES
        val text = if (oversized) null else try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(target.readBytes())).toString()
        } catch (_: CharacterCodingException) {
            null
        }
        return buildJsonObject {
            put("text", text)
            put("unsupported", if (text == null && !oversized) "This file is not UTF-8 text and cannot be read on this device yet." else null)
            put("truncated", oversized)
        }
    }

    private fun item(path: String, file: File) = buildJsonObject {
        put("path", path)
        put("name", path.substringAfterLast('/'))
        put("kind", if (file.isDirectory) "directory" else "file")
        put("size", if (file.isDirectory) 0 else file.length())
        put("mtimeMs", file.lastModified())
    }

    private fun locate(capability: Capability, path: String): Location {
        val parts = path.split('/')
        if (parts.any { it.isEmpty() || it == "." || it == ".." }) throw Refusal("invalid", "Invalid path")
        val repository = parts.getOrNull(1)
        val (root, depth, writable) = when {
            parts.first() == FILES -> Triple(files, 1, parts.size > 1)
            parts.first() == TEMPORARY -> Triple(scratch(capability.conversation), 1, false)
            parts.first() == SKILLS -> Triple(File(bundle, SKILLS), 1, false)
            parts.first() == REPOSITORIES && repository == BUILTIN -> Triple(bundle, 2, false)
            parts.first() == REPOSITORIES && repository == LOCAL -> Triple(local, 2, parts.size > 2)
            else -> throw Refusal("not_found", "No mount owns this path")
        }
        val target = parts.drop(depth).fold(root) { parent, name -> File(parent, name) }
        val base = root.canonicalPath
        val resolved = target.canonicalPath
        if (resolved != base && !resolved.startsWith(base + File.separator)) throw Refusal("permission_denied", "Path leaves its mount")
        return Location(target, writable)
    }

    private fun scratch(conversation: Int) = File(temporary, conversation.toString())

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    companion object {
        private const val FILES = "files"
        private const val TEMPORARY = "tmp"
        private const val SKILLS = "skills"
        const val REPOSITORIES = "repositories"
        const val BUILTIN = "builtin"
        const val LOCAL = "local"
        private const val MAX_ENTRIES = 10_000
        private val ROOTS = setOf(FILES, TEMPORARY, SKILLS, REPOSITORIES)
        private const val MAX_FILE_BYTES = 32 * 1024 * 1024
        private val MUTATIONS = setOf("write", "mkdir", "move", "copy", "rm")
        private val WRITERS = setOf("write", "edit")
    }
}
