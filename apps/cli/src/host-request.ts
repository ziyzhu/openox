import { HostRPCClient, callHost } from "./host-rpc.ts";
import { failResult, type CliContext } from "./lib.ts";
import { HostRPCError } from "./host-connection.ts";

export async function requireHost(method: string, context: CliContext, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  try {
    return await callHost(method, { ...(context.chat ? { sessionId: context.chat } : {}), ...params }, timeoutMs, context.host);
  } catch (error) {
    const message = error instanceof HostRPCError && error.code === -32601
      ? `Host does not support ${method}; update Ox on the Host device`
      : (error as Error).message;
    return failResult(method, message);
  }
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
