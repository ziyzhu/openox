import { DebugConnection, runOnce, type DebugResult } from "./debug-ws.ts";
import { failResult, type CliContext } from "./lib.ts";

export function requestHost(
  kind: string,
  context: CliContext,
  timeoutMs: number,
  fields: Record<string, unknown> = {},
): Promise<DebugResult> {
  return runOnce({
    kind,
    id: crypto.randomUUID(),
    ...(context.chat ? { sessionId: context.chat } : {}),
    ...fields,
  }, timeoutMs, context.host);
}

export async function requireHost(
  kind: string,
  context: CliContext,
  timeoutMs: number,
  fields: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const result = await requestHost(kind, context, timeoutMs, fields);
  if (!result.ok) failResult(kind, result.error);
  return result;
}

export function connectHost(context: CliContext): {
  request(kind: string, timeoutMs: number, fields?: Record<string, unknown>): Promise<DebugResult>;
  close(): void;
} {
  const connection = new DebugConnection(context.host);
  return {
    request(kind, timeoutMs, fields = {}) {
      return connection.request({
        kind,
        id: crypto.randomUUID(),
        ...(context.chat ? { sessionId: context.chat } : {}),
        ...fields,
      }, timeoutMs);
    },
    close() {
      connection.close();
    },
  };
}
