import { RPC_VERSION, validateParams, validateResult, type ProfileDescription, type ConversationRow } from "@openox/protocol";
import { ProfileConnection, ProfileRPCError, isObject } from "./profile-connection.ts";

export type { ProfileDescription, ConversationRow } from "@openox/protocol";

const DESCRIBE_METHODS = new Set(["profile.describe", "host.describe"]);

export class ProfileRPCClient {
  private readonly connection: ProfileConnection;
  private versionCheck?: { generation: number; ready: Promise<void> };

  constructor(endpoint?: string) {
    this.connection = new ProfileConnection(endpoint);
  }

  async call(method: string, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (!validateParams(method, params)) throw new Error(`Invalid ${method} parameters; request not sent`);
    const deadline = Date.now() + timeoutMs;
    if (!DESCRIBE_METHODS.has(method)) await this.checkVersion(timeoutMs);
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error(`Timeout before ${method}; request not sent`);
    const result = await this.connection.request(method, params, remaining);
    if (!isObject(result) || !validateResult(method, result)) {
      const label = method === "conversations.list" ? "conversation list" : `${method} result`;
      throw new Error(`Ox returned an invalid ${label}; request was sent, inspect the Profile before retrying. This request was not automatically resent.`);
    }
    return result;
  }

  private checkVersion(timeoutMs: number): Promise<void> {
    const generation = this.connection.generation;
    if (this.versionCheck?.generation === generation) return this.versionCheck.ready;
    const ready = this.describe(timeoutMs).then(description => {
      const supported = description.protocols.rpc ?? [];
      if (!supported.includes(RPC_VERSION)) {
        throw new Error(`Ox RPC interface revisions ${supported.join(", ") || "unversioned"} do not support CLI revision ${RPC_VERSION}; update Ox and the CLI together. Operation request not sent.`);
      }
    });
    this.versionCheck = { generation, ready };
    return ready;
  }

  async describe(timeoutMs: number): Promise<ProfileDescription> {
    try {
      return await this.call("profile.describe", timeoutMs) as ProfileDescription;
    } catch (error) {
      if (!(error instanceof ProfileRPCError) || error.code !== -32601) throw error;
      return await this.call("host.describe", timeoutMs) as ProfileDescription;
    }
  }

  async listConversations(timeoutMs: number): Promise<ConversationRow[]> {
    return (await this.call("conversations.list", timeoutMs)).conversations as ConversationRow[];
  }

  close(): void { this.connection.close(); }
}

export async function callProfile(method: string, params: Record<string, unknown>, timeoutMs: number, endpoint?: string): Promise<Record<string, unknown>> {
  const client = new ProfileRPCClient(endpoint);
  try { return await client.call(method, timeoutMs, params); }
  finally { client.close(); }
}
