import { ProfileRPCClient, callProfile } from "./profile-rpc.ts";
import { failResult, type CliContext } from "./lib.ts";
import { ProfileRPCError } from "./profile-connection.ts";

export async function requireEndpoint(method: string, context: CliContext, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  try {
    return await callProfile(method, { ...(context.conversation ? { conversationId: context.conversation } : {}), ...params }, timeoutMs, context.endpoint);
  } catch (error) {
    const message = error instanceof ProfileRPCError && error.code === -32601
      ? `Ox does not support ${method}; update Ox on the device`
      : (error as Error).message;
    return failResult(method, message);
  }
}

export function connectProfile(context: CliContext) {
  const client = new ProfileRPCClient(context.endpoint);
  return {
    request(method: string, timeoutMs: number, params: Record<string, unknown> = {}) {
      return client.call(method, timeoutMs, { ...(context.conversation ? { conversationId: context.conversation } : {}), ...params });
    },
    close() { client.close(); },
  };
}
