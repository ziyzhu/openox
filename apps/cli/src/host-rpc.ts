import { validateParams, validateResult, type HostDescription, type HostChatRow } from "@openox/protocol";
import { HostConnection, isObject } from "./host-connection.ts";

export type { HostDescription, HostChatRow } from "@openox/protocol";

export class HostRPCClient {
  private readonly connection: HostConnection;

  constructor(endpoint?: string) {
    this.connection = new HostConnection(endpoint);
  }

  async call(method: string, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (!validateParams(method, params)) throw new Error(`Invalid ${method} parameters; request not sent`);
    const result = await this.connection.request(method, params, timeoutMs);
    if (!isObject(result) || !validateResult(method, result)) {
      const label = method === "chats.list" ? "chat list" : `${method} result`;
      throw new Error(`Host returned an invalid ${label}; request was sent, inspect Host state before retrying. This request was not automatically resent.`);
    }
    return result;
  }

  async describe(timeoutMs: number): Promise<HostDescription> {
    return await this.call("host.describe", timeoutMs) as HostDescription;
  }

  async listChats(timeoutMs: number): Promise<HostChatRow[]> {
    return (await this.call("chats.list", timeoutMs)).chats as HostChatRow[];
  }

  close(): void { this.connection.close(); }
}

export async function callHost(method: string, params: Record<string, unknown>, timeoutMs: number, endpoint?: string): Promise<Record<string, unknown>> {
  const client = new HostRPCClient(endpoint);
  try { return await client.call(method, timeoutMs, params); }
  finally { client.close(); }
}
