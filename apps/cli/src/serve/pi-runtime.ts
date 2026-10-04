import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";

type RecordValue = Record<string, any>;
const dialogs = new Set(["confirm", "select", "input", "editor"]);

/** Pi's subprocess protocol is strict LF-delimited JSON, not readline framing. */
export class PiRuntime {
  readonly id = randomUUID();
  readonly interactions = new Map<string, RecordValue>();
  revision = 0;
  latestEvent: RecordValue | undefined;
  alive = true;
  working = false;
  private readonly process: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<string, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  private input = "";
  private writes: Promise<void> = Promise.resolve();

  constructor(executable: string, cwd: string, args: string[], onExit: (code: number | null, signal: NodeJS.Signals | null) => void) {
    this.process = spawn(executable, ["--mode", "rpc", ...args], { cwd, stdio: "pipe" });
    this.process.stdout.setEncoding("utf8");
    this.process.stdout.on("data", (chunk: string) => this.consume(chunk));
    // Drain diagnostics without forwarding possibly sensitive provider output to MCP clients.
    this.process.stderr.resume();
    this.process.stdin.on("error", (error) => this.failed(error));
    this.process.on("error", (error) => this.failed(error));
    this.process.on("exit", (code, signal) => {
      onExit(code, signal);
      this.failed(new Error(`Pi exited (${signal ?? code}). Check Pi credentials and project trust locally.`));
    });
  }

  private failed(error: Error): void {
    this.alive = false;
    this.interactions.clear();
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }

  private consume(chunk: string): void {
    this.input += chunk;
    if (Buffer.byteLength(this.input) > 32 * 1024 * 1024) {
      this.failed(new Error("Pi RPC output exceeded 32 MiB"));
      this.process.kill();
      return;
    }
    let newline: number;
    while ((newline = this.input.indexOf("\n")) !== -1) {
      const line = this.input.slice(0, newline).replace(/\r$/, "");
      this.input = this.input.slice(newline + 1);
      if (!line) continue;
      let record: RecordValue;
      try { record = JSON.parse(line); }
      catch { this.failed(new Error("Invalid Pi RPC JSON")); this.process.kill(); return; }
      if (record.type === "response") {
        const request = this.pending.get(record.id);
        if (!request) continue;
        this.pending.delete(record.id);
        if (record.success) request.resolve(record.data ?? {});
        else request.reject(new Error(record.error ?? "Pi command failed"));
        continue;
      }
      this.revision++;
      this.latestEvent = record;
      if (record.type === "agent_start") this.working = true;
      if (record.type === "agent_settled") this.working = false;
      if (record.type === "extension_ui_request" && dialogs.has(record.method)) {
        this.interactions.set(record.id, { ...record, expiresAt: record.timeout ? Date.now() + record.timeout : undefined });
      }
      if (record.type === "agent_settled") this.interactions.clear();
    }
  }

  private write(record: RecordValue): Promise<void> {
    const next = this.writes.then(async () => {
      if (!this.alive) throw new Error("Pi is not running; resume the session");
      const writable = this.process.stdin.write(JSON.stringify(record) + "\n");
      if (!writable) await once(this.process.stdin, "drain");
    });
    this.writes = next.catch(() => {});
    return next;
  }

  async request(type: string, params: RecordValue = {}): Promise<any> {
    const id = randomUUID();
    let timer: ReturnType<typeof setTimeout>;
    const response = new Promise<any>((resolve, reject) => {
      timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Pi ${type} timed out; delivery may be unknown. Do not blindly resend mutations.`));
      }, 30_000);
      this.pending.set(id, { resolve, reject });
    });
    void response.catch(() => {}); // Startup/exit can reject before stdin drains.
    try {
      await this.write({ ...params, type, id });
      return await response;
    } catch (error) {
      this.pending.get(id)?.reject(error as Error);
      await response.catch(() => {});
      throw error;
    } finally { clearTimeout(timer!); this.pending.delete(id); }
  }

  pendingInteractions(): RecordValue[] {
    for (const [id, request] of this.interactions) {
      if (request.expiresAt && request.expiresAt <= Date.now()) this.interactions.delete(id);
    }
    return [...this.interactions.values()];
  }

  async respond(id: string, response: { confirmed?: boolean; value?: string; cancelled?: boolean }): Promise<void> {
    const request = this.pendingInteractions().find((item) => item.id === id);
    if (!request) throw new Error("Interaction is expired or unknown");
    if (!response.cancelled) {
      if (request.method === "confirm" && typeof response.confirmed !== "boolean") throw new Error("Confirmation requires confirmed");
      if (request.method !== "confirm" && typeof response.value !== "string") throw new Error("Interaction requires value");
      if (request.method === "select" && !request.options.includes(response.value)) throw new Error("Invalid selection");
    }
    await this.write({ type: "extension_ui_response", id, ...response });
    this.interactions.delete(id);
  }

  async close(): Promise<void> {
    if (!this.alive) return;
    const exited = once(this.process, "exit");
    const force = setTimeout(() => this.process.kill("SIGKILL"), 5000);
    try {
      await this.request("clear_queue").catch(() => {});
      await this.request("abort").catch(() => {});
      this.process.stdin.end();
      await exited;
    } finally { clearTimeout(force); }
  }
}
