import { createCipheriv, createHash, randomBytes } from "node:crypto";
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AgentPushRegistration } from "@openox/protocol/agent";
import { PUSH_BODY_LIMIT, PUSH_TITLE_LIMIT, type PushMessage, type PushRelayRequest } from "@openox/protocol/push";
import { agentLog } from "./agent-log.ts";

const RELAY_URL = process.env.OX_PUSH_RELAY ?? "https://push-relay.invalid/";
const MAX_DEVICES = 20;

export class PushRegistry {
  private devices = new Map<string, AgentPushRegistration>();
  private saving: Promise<void> = Promise.resolve();
  private readonly path: string;
  private readonly directory: string;

  constructor(directory: string) {
    this.directory = directory;
    this.path = join(directory, "push.json");
  }

  async load(): Promise<void> {
    const stored = await readFile(this.path, "utf8").then(JSON.parse, () => undefined);
    if (stored?.format === 1 && Array.isArray(stored.devices)) {
      this.devices = new Map(stored.devices.map((device: AgentPushRegistration) => [device.token, device]));
    }
  }

  register(device: AgentPushRegistration): Promise<void> {
    if (Buffer.from(device.key, "base64").length !== 32) throw new Error("notifications.register needs a base64 256-bit key");
    this.devices.delete(device.token);
    this.devices.set(device.token, device);
    while (this.devices.size > MAX_DEVICES) this.devices.delete(this.devices.keys().next().value!);
    agentLog("push.register", { environment: device.environment, kinds: device.kinds.join(","), devices: this.devices.size });
    return this.persist();
  }

  unregister(token: string): Promise<void> {
    if (!this.devices.delete(token)) return this.saving;
    agentLog("push.unregister", { devices: this.devices.size });
    return this.persist();
  }

  send(message: PushMessage): void {
    const sealed: PushMessage = { ...message, title: message.title.slice(0, PUSH_TITLE_LIMIT), body: message.body.slice(0, PUSH_BODY_LIMIT) };
    for (const device of this.devices.values()) {
      if (device.kinds.includes(message.kind)) void this.forward(device, sealed);
    }
  }

  private async forward(device: AgentPushRegistration, message: PushMessage): Promise<void> {
    const started = performance.now();
    const request: PushRelayRequest = { token: device.token, environment: device.environment, sealed: seal(device.key, message), thread: thread(message.conversation) };
    const status = await fetch(RELAY_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(request),
      signal: AbortSignal.timeout(15_000),
    }).then((response) => response.status, () => 0);
    agentLog("push.send", { kind: message.kind, conversation: message.conversation, status, durationMs: Math.round(performance.now() - started) });
    if (status === 410) await this.unregister(device.token);
  }

  private persist(): Promise<void> {
    this.saving = this.saving.then(() => this.save(), () => this.save());
    return this.saving;
  }

  private async save(): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    const temporary = `${this.path}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify({ format: 1, devices: [...this.devices.values()] }, null, 2)}\n`, { mode: 0o600 });
    await chmod(temporary, 0o600);
    await rename(temporary, this.path);
  }
}

function seal(key: string, message: PushMessage): string {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", Buffer.from(key, "base64"), nonce);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(message), "utf8"), cipher.final()]);
  return Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]).toString("base64");
}

function thread(conversation: string): string {
  return createHash("sha256").update(conversation).digest("hex").slice(0, 32);
}
