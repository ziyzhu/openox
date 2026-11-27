package ai.openox.ox.runtime.durable

import androidx.sqlite.SQLITE_DATA_BLOB
import androidx.sqlite.SQLITE_DATA_FLOAT
import androidx.sqlite.SQLITE_DATA_INTEGER
import androidx.sqlite.SQLITE_DATA_NULL
import androidx.sqlite.SQLITE_DATA_TEXT
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

class AgentDatabaseException(message: String) : Exception(message)

class AgentDatabase(private val file: File) {
    private sealed interface State {
        data object Unopened : State
        class Open(val connection: SQLiteConnection) : State
        data object Closed : State
    }

    private var state: State = State.Unopened

    fun perform(op: String, sql: String, params: JsonArray): JsonElement {
        if (op == "close") {
            close()
            return JsonNull
        }
        val connection = connection()
        if (op == "exec") {
            SqlScript.statements(sql).forEach { statement -> connection.prepare(statement).use { it.step() } }
            return JsonNull
        }
        if (op !in OPERATIONS) throw AgentDatabaseException("Unknown SQL operation")
        val rows = mutableListOf<JsonObject>()
        connection.prepare(sql).use { statement ->
            params.forEachIndexed { index, value -> bind(statement, index + 1, value) }
            var bytes = 0L
            while (statement.step()) {
                if (op != "get" && op != "all") continue
                rows += buildJsonObject {
                    for (column in 0 until statement.getColumnCount()) {
                        val cell = value(statement, column)
                        if (cell is JsonPrimitive && cell.isString) bytes += cell.content.length
                        put(statement.getColumnName(column), cell)
                    }
                }
                if (bytes > RESULT_BYTE_LIMIT) throw AgentDatabaseException("SQL result exceeds the size limit")
            }
        }
        return when (op) {
            "runCounted" -> connection.prepare("SELECT changes()").use { it.step(); JsonPrimitive(it.getLong(0)) }
            "get" -> rows.firstOrNull() ?: JsonNull
            "all" -> JsonArray(rows)
            else -> JsonNull
        }
    }

    fun close() {
        val current = state
        state = State.Closed
        if (current is State.Open) current.connection.close()
    }

    private fun connection(): SQLiteConnection = when (val current = state) {
        is State.Open -> current.connection
        State.Closed -> throw AgentDatabaseException("Database closed")
        State.Unopened -> {
            file.parentFile?.mkdirs()
            val opened = BundledSQLiteDriver().open(file.path)
            try {
                PRAGMAS.forEach { pragma -> opened.prepare(pragma).use { it.step() } }
            } catch (error: Exception) {
                opened.close()
                throw error
            }
            state = State.Open(opened)
            opened
        }
    }

    private fun bind(statement: SQLiteStatement, index: Int, value: JsonElement) {
        when {
            value is JsonNull -> statement.bindNull(index)
            value is JsonPrimitive && value.isString -> statement.bindText(index, value.content)
            value is JsonPrimitive && value.contentOrNull in BOOLEANS -> statement.bindLong(index, if (value.content == "true") 1 else 0)
            value is JsonPrimitive -> statement.bindDouble(index, value.doubleOrNull ?: throw AgentDatabaseException("Unsupported SQL binding"))
            value is JsonObject && value["integer"] is JsonPrimitive ->
                statement.bindLong(index, (value["integer"] as JsonPrimitive).content.toLongOrNull() ?: throw AgentDatabaseException("Unsupported SQL binding"))
            value is JsonObject && value["blob"] is JsonArray -> {
                val bytes = (value["blob"] as JsonArray).map { ((it as? JsonPrimitive)?.intOrNull ?: throw AgentDatabaseException("Unsupported SQL binding")).toByte() }
                statement.bindBlob(index, bytes.toByteArray())
            }
            else -> throw AgentDatabaseException("Unsupported SQL binding")
        }
    }

    private fun value(statement: SQLiteStatement, column: Int): JsonElement = when (statement.getColumnType(column)) {
        SQLITE_DATA_NULL -> JsonNull
        SQLITE_DATA_INTEGER -> {
            val integer = statement.getLong(column)
            if (integer in -MAX_SAFE_INTEGER..MAX_SAFE_INTEGER) JsonPrimitive(integer) else buildJsonObject { put("integer", JsonPrimitive(integer.toString())) }
        }
        SQLITE_DATA_FLOAT -> JsonPrimitive(statement.getDouble(column))
        SQLITE_DATA_TEXT -> JsonPrimitive(statement.getText(column))
        SQLITE_DATA_BLOB -> buildJsonObject {
            put("blob", buildJsonArray { statement.getBlob(column).forEach { add(JsonPrimitive(it.toInt() and 0xFF)) } })
        }
        else -> throw AgentDatabaseException("Unsupported SQLite result")
    }

    private companion object {
        val OPERATIONS = setOf("run", "runCounted", "get", "all")
        val BOOLEANS = setOf("true", "false")
        val PRAGMAS = listOf("PRAGMA journal_mode=DELETE", "PRAGMA synchronous=FULL", "PRAGMA foreign_keys=ON")
        const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
        const val RESULT_BYTE_LIMIT = 64L * 1024 * 1024
    }
}

object SqlScript {
    fun statements(script: String): List<String> {
        val statements = mutableListOf<String>()
        val current = StringBuilder()
        var index = 0
        while (index < script.length) {
            val char = script[index]
            val next = script.getOrNull(index + 1)
            when {
                char == '-' && next == '-' -> index = script.indexOf('\n', index).let { if (it < 0) script.length else it }
                char == '/' && next == '*' -> index = script.indexOf("*/", index + 2).let { if (it < 0) script.length else it + 2 }
                char == '\'' || char == '"' || char == '`' || char == '[' -> {
                    val end = quoteEnd(script, index, if (char == '[') ']' else char)
                    current.append(script, index, end)
                    index = end
                }
                char == ';' && !insideTrigger(current) -> {
                    flush(current, statements)
                    index += 1
                }
                else -> {
                    current.append(char)
                    index += 1
                }
            }
        }
        flush(current, statements)
        return statements
    }

    private fun quoteEnd(script: String, start: Int, close: Char): Int {
        var index = start + 1
        while (index < script.length) {
            if (script[index] == close) {
                if (close != ']' && script.getOrNull(index + 1) == close) index += 2 else return index + 1
            } else {
                index += 1
            }
        }
        return script.length
    }

    private fun insideTrigger(current: StringBuilder): Boolean =
        TRIGGER.containsMatchIn(current) && !TRIGGER_END.containsMatchIn(current)

    private fun flush(current: StringBuilder, statements: MutableList<String>) {
        val statement = current.toString().trim()
        if (statement.isNotEmpty()) statements += statement
        current.clear()
    }

    private val TRIGGER = Regex("""^\s*CREATE\s+(TEMP\s+|TEMPORARY\s+)?TRIGGER\b""", RegexOption.IGNORE_CASE)
    private val TRIGGER_END = Regex(""";\s*END\s*$""", RegexOption.IGNORE_CASE)
}
