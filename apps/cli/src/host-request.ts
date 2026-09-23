import { HostRPCClient, callHost } from "./host-rpc.ts";
import { failResult, type CliContext } from "./lib.ts";

export async function requireHost(method: string, context: CliContext, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  try {
    return await callHost(method, { ...(context.chat ? { sessionId: context.chat } : {}), ...params }, timeoutMs, context.host);
  } catch (error) { return failResult(method, (error as Error).message); }
}

export function connectHost(context: CliContext) {
  const client = new HostRPCClient(context.host);
  return {
    request(method: string, timeoutMs: number, params: Record<string, unknown> = {}) {
      return client.call(method, timeoutMs, { ...(context.chat ? { sessionId: context.chat } : {}), ...params });
    },
    close() { client.close(); },
  };
}
