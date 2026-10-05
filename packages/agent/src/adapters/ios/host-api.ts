import "./encoding";
import clone from "@ungap/structured-clone";
import { AbortController, AbortSignal } from "abort-controller/dist/abort-controller.mjs";
import { URL, URLSearchParams } from "whatwg-url";

declare const __oxDurableTimer: (callback: () => void, milliseconds: number) => number;
declare const __oxDurableClearTimer: (id: number) => void;
declare const __oxDurableLog: (level: string, message: string) => void;

class HostDOMException extends Error {
  constructor(message = "", name = "Error") { super(message); this.name = name; }
}
const reasons = new WeakMap<AbortSignal, unknown>();
class HostAbortController extends AbortController {
  override abort(reason?: unknown) {
    if (!this.signal.aborted) {
      reasons.set(this.signal, reason === undefined ? new HostDOMException("Aborted", "AbortError") : reason);
    }
    super.abort();
  }
}
Object.defineProperties(AbortSignal.prototype, {
  reason: { get(this: AbortSignal) { return reasons.get(this); } },
  throwIfAborted: { value(this: AbortSignal) { if (this.aborted) throw reasons.get(this); } },
});
function any(signals: Iterable<AbortSignal>) {
  const inputs = Array.from(signals);
  for (const signal of inputs) if (!(signal instanceof AbortSignal)) throw new TypeError("Expected AbortSignal");
  const controller = new HostAbortController();
  const listeners: [AbortSignal, () => void][] = [];
  const cleanup = () => { for (const [signal, listener] of listeners) signal.removeEventListener("abort", listener); };
  for (const signal of inputs) {
    if (signal.aborted) { controller.abort(reasons.get(signal)); cleanup(); break; }
    const listener = () => { controller.abort(reasons.get(signal)); cleanup(); };
    listeners.push([signal, listener]);
    signal.addEventListener("abort", listener, { once: true });
  }
  return controller.signal;
}
Object.defineProperties(AbortSignal, {
  any: { value: any },
  abort: { value: (reason?: unknown) => { const c = new HostAbortController(); c.abort(reason); return c.signal; } },
});
const log = (level: string, values: unknown[]) => __oxDurableLog(level, values.map(String).join(" ").slice(0, 4096));
Object.assign(globalThis, {
  console: {
    assert: (condition: unknown, ...values: unknown[]) => { if (!condition) log("error", ["Assertion failed", ...values]); },
    error: (...values: unknown[]) => log("error", values),
    warn: (...values: unknown[]) => log("warning", values),
    log: (...values: unknown[]) => log("debug", values),
    debug: (...values: unknown[]) => log("debug", values),
  },
  AbortController: HostAbortController, AbortSignal, URL, URLSearchParams, DOMException: HostDOMException,
  structuredClone: clone,
  setTimeout: (callback: (...args: unknown[]) => void, ms = 0, ...args: unknown[]) => {
    if (typeof callback !== "function") throw new TypeError("Timer callback must be a function");
    return __oxDurableTimer(() => callback(...args), Math.max(0, Math.min(Number(ms) || 0, 2_147_483_647)));
  },
  clearTimeout: (id: number) => __oxDurableClearTimer(id),
  queueMicrotask: (callback: () => void) => {
    if (typeof callback !== "function") throw new TypeError("Microtask must be a function");
    void Promise.resolve().then(callback).catch(error => {
      __oxDurableTimer(() => { throw error; }, 0);
    });
  },
});
