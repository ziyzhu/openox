import { RPC_VERSION, validateParams, validateResult, type HostDescription, type HostChatRow } from "@openox/protocol";
import { HostConnection, isObject } from "./host-connection.ts";

export type { HostDescription, HostChatRow } from "@openox/protocol";

export class HostRPCClient {
  private readonly connection: HostConnection;
  private versionCheck?: { generation: number; ready: Promise<void> };

  constructor(endpoint?: string) {
    this.connection = new HostConnection(endpoint);
  }

  async call(method: string, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (!validateParams(method, params)) throw new Error(`Invalid ${method} parameters; request not sent`);
    const deadline = Date.now() + timeoutMs;
    if (method !== "host.describe") await this.checkVersion(timeoutMs);
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error(`Timeout before ${method}; request not sent`);
    const result = await this.connection.request(method, params, remaining);
    if (!isObject(result) || !validateResult(method, result)) {
      const label = method === "chats.list" ? "chat list" : `${method} result`;
      throw new Error(`Host returned an invalid ${label}; request was sent, inspect Host state before retrying. This request was not automatically resent.`);
    }
    return result;
  }

  private checkVersion(timeoutMs: number): Promise<void> {
    const generation = this.connection.generation;
    if (this.versionCheck?.generation === generation) return this.versionCheck.ready;
    const ready = this.describe(timeoutMs).then(description => {
      const supported = description.protocols.rpc ?? [];
      if (!supported.includes(RPC_VERSION)) {
        throw new Error(`Host RPC interface revisions ${supported.join(", ") || "unversioned"} do not support CLI revision ${RPC_VERSION}; update the Host and CLI together. Operation request not sent.`);
      }
    });
    this.versionCheck = { generation, ready };
    return ready;
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
