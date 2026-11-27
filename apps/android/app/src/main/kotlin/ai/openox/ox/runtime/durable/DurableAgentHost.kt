package ai.openox.ox.runtime.durable

import ai.openox.ox.diagnostics.OxLog
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.asyncFunction
import com.dokar.quickjs.binding.function
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

class AgentRuntimeException(message: String) : Exception(message)

fun interface AgentNativeHandler {
    suspend fun handle(method: String, params: JsonObject, stream: (JsonElement) -> Unit): JsonElement
}

class AgentRuntime(
    private val bundle: () -> String,
    private val database: AgentDatabase,
    private val handler: AgentNativeHandler,
) {
    private sealed interface State {
        data object Unopened : State
        class Open(val engine: QuickJs, val pump: Job) : State
        class Closed(val reason: String) : State
    }

    private val javascript = Executors.newSingleThreadExecutor { task -> Thread(null, task, "ox-agent-js", JS_STACK_BYTES) }.asCoroutineDispatcher()
    private val native = Executors.newSingleThreadExecutor { task -> Thread(task, "ox-agent-native") }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lifecycle = Mutex()
    private val inbox = Channel<String>(Channel.UNLIMITED)
    private val calls = ConcurrentHashMap<Int, CompletableDeferred<String>>()
    private val tasks = ConcurrentHashMap<Int, Job>()
    private val timers = ConcurrentHashMap<Int, Job>()
    private val nextCall = AtomicInteger()
    private val random = SecureRandom()

    @Volatile
    private var state: State = State.Unopened

    suspend fun command(value: JsonObject): JsonElement {
        open()
        val id = nextCall.incrementAndGet()
        val reply = CompletableDeferred<String>()
        calls[id] = reply
        post(buildJsonObject {
            put("kind", "command")
            put("entry", "agentCommand")
            put("json", value.toString())
            put("id", id)
        })
        try {
            return Json.parseToJsonElement(reply.await())
        } finally {
            calls.remove(id)
        }
    }

    suspend fun close() = lifecycle.withLock {
        val current = state
        if (current !is State.Open) return@withLock
        state = State.Closed("Agent runtime closed; reopen required")
        fail("Agent runtime closed; reopen required")
        inbox.send(STOP)
        current.pump.join()
        current.engine.close()
        scope.launch(native) { runCatching { database.close() }.onFailure { OxLog.error("agent.database.close.failed", "message" to it.message) } }.join()
        scope.cancel()
        javascript.close()
        native.close()
        OxLog.info("agent.runtime.closed")
    }

    private suspend fun open() = lifecycle.withLock {
        when (val current = state) {
            is State.Open -> return@withLock
            is State.Closed -> throw AgentRuntimeException(current.reason)
            State.Unopened -> Unit
        }
        val started = System.nanoTime()
        val source = bundle()
        val ready = CompletableDeferred<QuickJs>()
        val pump = scope.launch(javascript) {
            val engine = QuickJs.create(Dispatchers.Default)
            try {
                install(engine)
                engine.evaluate<Any?>(PRELUDE, "ox-trusted://prelude.js")
                engine.evaluate<Any?>(source, "ox-trusted://harness.js")
                ready.complete(engine)
                engine.evaluate<Any?>(PUMP, "ox-trusted://pump.js")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val message = error.message ?: error.javaClass.simpleName
                OxLog.error("agent.runtime.failed", "message" to message)
                state = State.Closed(message)
                ready.completeExceptionally(AgentRuntimeException(message))
                fail(message)
            }
        }
        val engine = ready.await()
        state = State.Open(engine, pump)
        OxLog.info("agent.runtime.opened", "bundleBytes" to source.length, "durationMs" to (System.nanoTime() - started) / 1_000_000)
    }

    private fun install(engine: QuickJs) {
        engine.asyncFunction("__oxHostNext") { inbox.receive() }
        engine.function("__oxHostTimer") { args ->
            val id = int(args[0])
            val milliseconds = (args[1] as Number).toLong().coerceAtLeast(1)
            timers[id] = scope.launch {
                delay(milliseconds)
                timers.remove(id)
                post(buildJsonObject {
                    put("kind", "timer")
                    put("id", id)
                })
            }
            null
        }
        engine.function("__oxHostClearTimer") { args ->
            timers.remove(int(args[0]))?.cancel()
            null
        }
        engine.function("__oxHostRandomHex") { args ->
            val count = int(args[0])
            if (count !in 0..MAX_RANDOM_BYTES) null
            else ByteArray(count).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        }
        engine.function("__oxHostFatal") { args ->
            val message = args[0].toString()
            OxLog.error("agent.javascript.exception", "message" to message)
            state = State.Closed(message)
            fail(message)
            null
        }
        engine.function("__oxDurableNow") { System.nanoTime() / 1_000_000.0 }
        engine.function("__oxDurableLog") { args ->
            val message = args[1].toString()
            when (args[0]) {
                "error" -> OxLog.error("agent.javascript", "message" to message)
                "warning" -> OxLog.warning("agent.javascript", "message" to message)
                else -> Unit
            }
            null
        }
        engine.function("__oxDurableComplete") { args ->
            val reply = calls.remove(int(args[0]))
            val error = args[2] as? String
            if (error != null) reply?.completeExceptionally(AgentRuntimeException(error)) else reply?.complete(args[1] as? String ?: "null")
            null
        }
        engine.function("__oxDurableRequest") { args ->
            request(int(args[0]), args[1].toString())
            null
        }
    }

    private fun request(id: Int, json: String) {
        val request = runCatching { Json.parseToJsonElement(json).jsonObject }.getOrNull()
        val method = (request?.get("method") as? JsonPrimitive)?.contentOrNull
        val params = request?.get("params") as? JsonObject
        if (method == null || params == null) {
            deliver(id, JsonNull, "Invalid native request")
            return
        }
        if (id == 0) {
            (params["id"] as? JsonPrimitive)?.intOrNull?.let { tasks.remove(it)?.cancel() }
            return
        }
        val dispatcher = if (method in SERIAL_METHODS) native else Dispatchers.Default
        tasks[id] = scope.launch(dispatcher) {
            try {
                deliver(id, perform(id, method, params), null)
            } catch (error: CancellationException) {
                deliver(id, JsonNull, "Native operation cancelled")
                throw error
            } catch (error: Exception) {
                OxLog.warning("agent.native.failed", "method" to method, "message" to error.message)
                deliver(id, JsonNull, error.message ?: error.javaClass.simpleName)
            } finally {
                tasks.remove(id)
            }
        }
    }

    private suspend fun perform(id: Int, method: String, params: JsonObject): JsonElement = when (method) {
        "sql" -> {
            val op = (params["op"] as? JsonPrimitive)?.contentOrNull
            val sql = (params["sql"] as? JsonPrimitive)?.contentOrNull
            val bindings = params["params"] as? JsonArray
            if (op == null || sql == null || bindings == null) throw AgentRuntimeException("Invalid SQL request")
            database.perform(op, sql, bindings)
        }
        "uuid" -> JsonPrimitive(UUID.randomUUID().toString().uppercase())
        "report" -> {
            OxLog.warning("agent.report", "message" to (params["message"] as? JsonPrimitive)?.contentOrNull)
            JsonNull
        }
        else -> handler.handle(method, params) { event ->
            if (tasks.containsKey(id)) post(buildJsonObject {
                put("kind", "event")
                put("id", id)
                put("json", event.toString())
            })
        }
    }

    private fun deliver(id: Int, value: JsonElement, error: String?) = post(buildJsonObject {
        put("kind", "deliver")
        put("id", id)
        put("json", value.toString())
        put("error", error)
    })

    private fun post(message: JsonObject) {
        inbox.trySend(message.toString())
    }

    private fun fail(message: String) {
        calls.keys.toList().forEach { id -> calls.remove(id)?.completeExceptionally(AgentRuntimeException(message)) }
        tasks.values.forEach { it.cancel() }
        timers.values.forEach { it.cancel() }
    }

    private fun int(value: Any?): Int = (value as Number).toInt()

    private companion object {
        const val STOP = ""
        const val MAX_RANDOM_BYTES = 65_536
        const val JS_STACK_BYTES = 16L * 1024 * 1024
        val SERIAL_METHODS = setOf("sql", "uuid", "report")

        val PRELUDE = """
            (() => {
              const timers = new Map();
              let next = 0;
              globalThis.__oxDurableTimer = (callback, milliseconds) => {
                const id = ++next;
                timers.set(id, callback);
                __oxHostTimer(id, milliseconds);
                return id;
              };
              globalThis.__oxDurableClearTimer = id => { if (timers.delete(id)) __oxHostClearTimer(id); };
              globalThis.__oxDurableRandomBytes = count => {
                const hex = __oxHostRandomHex(count);
                if (hex === null || hex === undefined) return null;
                const bytes = new Array(count);
                for (let index = 0; index < count; index++) bytes[index] = parseInt(hex.substr(index * 2, 2), 16);
                return bytes;
              };
              globalThis.__oxHostFire = id => {
                const callback = timers.get(id);
                if (!callback) return;
                timers.delete(id);
                callback();
              };
            })();
        """.trimIndent()

        val PUMP = """
            globalThis.__oxDurableCommand = (entry, json, id) => {
              Promise.resolve().then(() => OxDurable[entry](JSON.parse(json))).then(
                value => __oxDurableComplete(id, JSON.stringify(value), null),
                error => __oxDurableComplete(id, null, typeof error.code === 'string' && typeof error.recovery === 'string'
                  ? JSON.stringify({ code: error.code, message: error.message, recovery: error.recovery })
                  : String(error) + '\n' + (error.stack || ''))
              );
            };
            await (async () => {
              for (;;) {
                const raw = await __oxHostNext();
                if (raw === '') return;
                try {
                  const message = JSON.parse(raw);
                  if (message.kind === 'command') __oxDurableCommand(message.entry, message.json, message.id);
                  else if (message.kind === 'deliver') OxDurable.deliver(message.id, message.json, message.error);
                  else if (message.kind === 'event') OxDurable.streamEvent(message.id, message.json);
                  else if (message.kind === 'timer') __oxHostFire(message.id);
                } catch (error) {
                  __oxHostFatal(String(error) + '\n' + (error.stack || ''));
                }
              }
            })();
        """.trimIndent()
    }
}
