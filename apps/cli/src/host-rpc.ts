import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";
import { HostConnection, isObject } from "./host-connection.ts";

const HostDescriptionSchema = Type.Object({
  implementation: Type.Object({ name: Type.String(), version: Type.String(), build: Type.String() }),
  protocols: Type.Object({ rpc: Type.Array(Type.Integer({ minimum: 1 })) }),
  methods: Type.Array(Type.String()),
});

export const RPC_VERSION = 1;

const ChatRowSchema = Type.Object({
  id: Type.String(),
  title: Type.String(),
  model: Type.Union([Type.String(), Type.Null()]),
  createdAt: Type.String(),
  lastActivity: Type.Union([Type.String(), Type.Null()]),
  active: Type.Boolean(),
});

const ChatListSchema = Type.Object({ chats: Type.Array(ChatRowSchema) });
export type HostDescription = Static<typeof HostDescriptionSchema>;
export type HostChatRow = Static<typeof ChatRowSchema>;

export class HostRPCClient {
  private readonly connection: HostConnection;
  private compatibleHost?: Promise<HostDescription>;

  constructor(endpoint?: string) {
    this.connection = new HostConnection(endpoint);
  }

  async call(method: string, timeoutMs: number, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (method === "host.describe") return this.describe(timeoutMs);
    await this.ensureCompatible(timeoutMs);
    const result = await this.connection.request(method, params, timeoutMs);
    if (!isObject(result)) throw new Error(`Host returned an invalid ${method} result`);
    return result;
  }

  async describe(timeoutMs: number): Promise<HostDescription> {
    const result = await this.connection.request("host.describe", {}, timeoutMs);
    if (!Value.Check(HostDescriptionSchema, result)) throw new Error("Host returned an invalid description");
    return result;
  }

  private ensureCompatible(timeoutMs: number): Promise<HostDescription> {
    this.compatibleHost ??= this.describe(timeoutMs).then(description => {
      const supported = description.protocols.rpc;
      if (!supported.includes(RPC_VERSION)) {
        throw new Error(`Host supports RPC versions ${supported.join(", ")}; this client uses RPC ${RPC_VERSION}. Update the Host and CLI together.`);
      }
      return description;
    }).catch(error => {
      this.compatibleHost = undefined;
      throw error;
    });
    return this.compatibleHost;
  }

  async listChats(timeoutMs: number): Promise<HostChatRow[]> {
    const result = await this.call("chats.list", timeoutMs);
    if (!Value.Check(ChatListSchema, result)) throw new Error("Host returned an invalid chat list");
    return result.chats;
  }

  close(): void { this.connection.close(); }
}

export async function callHost(method: string, params: Record<string, unknown>, timeoutMs: number, endpoint?: string): Promise<Record<string, unknown>> {
  const client = new HostRPCClient(endpoint);
  try { return await client.call(method, timeoutMs, params); }
  finally { client.close(); }
}
