package ai.openox.ox.runtime.vm

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.QuickJsException
import com.dokar.quickjs.binding.asyncFunction
import com.dokar.quickjs.binding.function
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

class ExecutionOutput(val lines: List<String>, val failure: String?)

class ExecutionVm(private val catalog: ToolCatalog) {
    suspend fun run(source: String, call: suspend (String, JsonObject, ExecutionBudget) -> JsonElement): ExecutionOutput {
        val budget = ExecutionBudget(ToolCatalog.TIMEOUT_SECONDS.seconds)
        val lines = mutableListOf<String>()
        var captured = 0
        var failure: String? = null
        try {
            JavaScript.run("ox-execute-js", budget, MEMORY_BYTES) { engine ->
                engine.function("__oxLog") { args ->
                    val message = args[1].toString()
                    if (captured <= CAPTURE_BYTES) {
                        captured += message.length
                        lines += if (captured > CAPTURE_BYTES) "[warn] Output capture limit reached; later output was dropped." else if (args[0] == "log") message else "[${args[0]}] $message"
                    }
                    null
                }
                engine.function("__oxFail") { args ->
                    failure = args[0].toString()
                    null
                }
                engine.function("__oxNames") { Json.encodeToString(catalog.names) }
                engine.function("__oxHelp") { catalog.help.toString() }
                engine.asyncFunction("__oxCall") { args ->
                    val name = args[0].toString()
                    try {
                        val arguments = Json.parseToJsonElement(args[1].toString()) as? JsonObject ?: throw OxFunctionError("invalid_arguments", "$name expects one options object")
                        buildJsonObject { put("value", call(name, arguments, budget)) }.toString()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        buildJsonObject {
                            putJsonObject("error") {
                                put("code", (error as? OxFunctionError)?.code ?: "failed")
                                put("message", error.message?.lineSequence()?.firstOrNull()?.removePrefix("Error: ") ?: error.javaClass.simpleName)
                            }
                        }.toString()
                    }
                }
                engine.evaluate<Any?>(PRELUDE, "ox-trusted://execute-prelude.js")
                engine.evaluate<Any?>("await __oxRun(async () => {\n$source\n});", "execute.js")
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: JavaScriptTimeout) {
            failure = error.message
        } catch (error: QuickJsException) {
            failure = error.message?.lineSequence()?.firstOrNull() ?: "JavaScript failed"
        }
        return ExecutionOutput(lines, failure)
    }

    private companion object {
        const val MEMORY_BYTES = 96L * 1024 * 1024
        const val CAPTURE_BYTES = 4 * 1024 * 1024

        val PRELUDE = """
            (() => {
              const describe = value => {
                if (typeof value === 'string') return value;
                if (value instanceof Error) return (value.code ? '[' + value.code + '] ' : '') + (value.name && value.name !== 'Error' ? value.name + ': ' : '') + value.message;
                if (value === undefined) return 'undefined';
                try {
                  const text = JSON.stringify(value, null, 2);
                  return text === undefined ? String(value) : text;
                } catch (error) {
                  return String(value);
                }
              };
              const emit = level => (...values) => { __oxLog(level, values.map(describe).join(' ')); };
              globalThis.console = { log: emit('log'), info: emit('info'), warn: emit('warn'), error: emit('error'), debug: emit('debug') };
              const page = (lines, result) => {
                const hints = (result.diagnostics ?? []).map(({ path, message }) => '[' + path + ': ' + message + ']');
                if (result.truncated) hints.push('[Results incomplete.]');
                if (result.nextCursor != null) hints.push('[Continue with cursor: ' + JSON.stringify(result.nextCursor) + ']');
                return [lines.join('\n'), hints.join('\n')].filter(Boolean).join('\n\n');
              };
              const shape = {
                'ox.fs.ls': result => page(result.items.length ? result.items.map(item => item.name + (item.type === 'directory' ? '/' : '')) : ['(empty directory)'], result),
                'ox.fs.read': result => {
                  if (result.type === 'image') return result;
                  if (result.unsupported) return result.unsupported;
                  const hints = result.diagnostics.map(entry => '[' + entry.message + ']');
                  if (result.nextOffset != null) hints.push('[More lines in file. Use offset=' + result.nextOffset + ' to continue.]');
                  if (result.nextByteOffset != null) hints.push('[More bytes in file. Use byteOffset=' + result.nextByteOffset + ' to continue.]');
                  return hints.length ? result.text + '\n\n' + hints.join('\n') : result.text;
                },
                'ox.fs.write': (result, value) => 'Successfully wrote to ' + value.path,
                'ox.fs.edit': (result, value) => 'Successfully replaced ' + value.edits.length + ' block(s) in ' + value.path + '.',
                'ox.fs.find': result => page(result.paths.length ? result.paths : ['No files found matching pattern'], result),
                'ox.fs.grep': result => page(result.matches.length ? result.matches.flatMap(({ path, line, text, before, after }) => [
                  ...before.map((text, index) => path + '-' + (line - before.length + index) + '- ' + text),
                  path + ':' + line + ': ' + text,
                  ...after.map((text, index) => path + '-' + (line + index + 1) + '- ' + text),
                ]) : ['No matches found'], result),
              };
              const help = JSON.parse(__oxHelp());
              const ox = { help: () => help.ox };
              for (const name of JSON.parse(__oxNames())) {
                const parts = name.split('.').slice(1);
                let owner = ox;
                parts.slice(0, -1).forEach((part, index) => {
                  if (!owner[part]) {
                    const path = 'ox.' + parts.slice(0, index + 1).join('.');
                    owner[part] = { help: () => help[path] ?? path };
                  }
                  owner = owner[part];
                });
                const invoke = async value => {
                  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new TypeError(name + ' expects one options object');
                  if (typeof value.purpose !== 'string' || !value.purpose) throw new TypeError(name + ' requires a short purpose');
                  const reply = JSON.parse(await __oxCall(name, JSON.stringify(value)));
                  if (reply.error) {
                    const error = new Error(reply.error.message);
                    error.code = reply.error.code;
                    throw error;
                  }
                  return shape[name] ? shape[name](reply.value, value) : reply.value;
                };
                invoke.help = () => help[name];
                owner[parts.at(-1)] = invoke;
              }
              globalThis.ox = ox;
              globalThis.image = async () => { throw new Error('image() is not available on this device yet'); };
              globalThis.__oxRun = async body => {
                try {
                  const value = await body();
                  if (value !== undefined) __oxLog('log', describe(value));
                } catch (error) {
                  __oxFail(describe(error));
                }
              };
            })();
        """.trimIndent()
    }
}

class JavaScriptTimeout(limit: Duration) : Exception("JavaScript exceeded its ${limit.inWholeSeconds} second limit")

class ExecutionBudget(val limit: Duration) {
    private val waiting = AtomicInteger()
    private val spent = AtomicLong()

    val exhausted: Boolean get() = spent.get() >= limit.inWholeMilliseconds

    fun tick(milliseconds: Long) {
        if (waiting.get() == 0) spent.addAndGet(milliseconds)
    }

    suspend fun <T> exempt(block: suspend () -> T): T {
        waiting.incrementAndGet()
        try {
            return block()
        } finally {
            waiting.decrementAndGet()
        }
    }
}

object JavaScript {
    suspend fun <T> run(thread: String, limit: Duration, memoryBytes: Long, block: suspend (QuickJs) -> T): T =
        run(thread, ExecutionBudget(limit), memoryBytes, block)

    suspend fun <T> run(thread: String, budget: ExecutionBudget, memoryBytes: Long, block: suspend (QuickJs) -> T): T {
        val dispatcher = Executors.newSingleThreadExecutor { task -> Thread(null, task, thread, STACK_BYTES) }.asCoroutineDispatcher()
        try {
            return withContext(dispatcher) {
                val engine = QuickJs.create(Dispatchers.Default)
                engine.memoryLimit = memoryBytes
                val expired = AtomicBoolean(false)
                val deadline = launch(Dispatchers.Default) {
                    while (!budget.exhausted) {
                        delay(TICK_MS)
                        budget.tick(TICK_MS)
                    }
                    expired.set(true)
                    engine.interruptEvaluation()
                }
                val cancellation = launch(Dispatchers.Default) {
                    try {
                        awaitCancellation()
                    } finally {
                        engine.interruptEvaluation()
                    }
                }
                try {
                    block(engine)
                } catch (error: QuickJsException) {
                    if (expired.get()) throw JavaScriptTimeout(budget.limit) else throw error
                } finally {
                    withContext(NonCancellable) {
                        deadline.cancelAndJoin()
                        cancellation.cancelAndJoin()
                        engine.close()
                    }
                }
            }
        } finally {
            dispatcher.close()
        }
    }

    private const val STACK_BYTES = 16L * 1024 * 1024
    private const val TICK_MS = 100L
}
