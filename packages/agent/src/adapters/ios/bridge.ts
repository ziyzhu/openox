declare const __oxDurableRequest: (id: number, json: string) => void;
let sequence = 0;
const pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void; cleanup(): void; event?(value: unknown): void }>();

export function native<T>(method: string, params: unknown, signal?: AbortSignal, event?: (value: unknown) => void): Promise<T> {
  signal?.throwIfAborted();
  const id = ++sequence;
  return new Promise<T>((resolve, reject) => {
    const abort = () => {
      pending.delete(id);
      signal?.removeEventListener("abort", abort);
      try { __oxDurableRequest(0, JSON.stringify({ method: "cancel", params: { id } })); }
      finally { reject(signal?.reason); }
    };
    pending.set(id, { resolve: value => resolve(value as T), reject, event, cleanup: () => signal?.removeEventListener("abort", abort) });
    signal?.addEventListener("abort", abort, { once: true });
    try { __oxDurableRequest(id, JSON.stringify({ method, params })); }
    catch (error) {
      pending.delete(id); signal?.removeEventListener("abort", abort); reject(error);
    }
  });
}

export function streamEvent(id: number, json: string) {
  const callbacks = pending.get(id);
  if (!callbacks) return;
  try { callbacks.event?.(JSON.parse(json)); }
  catch (error) {
    pending.delete(id); callbacks.cleanup(); callbacks.reject(error instanceof Error ? error : new Error(String(error)));
    try { __oxDurableRequest(0, JSON.stringify({ method: "cancel", params: { id } })); }
    catch (error) { console.warn("Native callback cancellation failed", String(error)); }
  }
}

export function deliver(id: number, json: string, error: string | null) {
  const callbacks = pending.get(id);
  if (!callbacks) return; // Native cancellation completion or an expired generation.
  pending.delete(id);
  callbacks.cleanup();
  if (error !== null) callbacks.reject(new Error(error));
  else {
    try { callbacks.resolve(JSON.parse(json)); }
    catch (error) { callbacks.reject(error instanceof Error ? error : new Error(String(error))); }
  }
}
