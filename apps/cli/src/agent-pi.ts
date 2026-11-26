import { agentLog } from "./agent-log.ts";

export type PiRecord = Record<string, unknown> & { type?: unknown };
export type PiExit = { code: number | null; requested: boolean; stderr: string };
export type Approval = "default" | "approve" | "no-approve";

const STDERR_TAIL_BYTES = 4096;
const SHUTDOWN_GRACE_MS = 5000;

export function piExecutable(): string {
  const override = process.env.OX_AGENT_PI;
  if (override) return override;
  const found = Bun.which("pi");
  if (!found) throw new Error("pi was not found on PATH; install pi or set OX_AGENT_PI to its executable");
  return found;
}

export async function piVersion(executable: string): Promise<string> {
  const child = Bun.spawn({ cmd: [executable, "--version"], stdout: "pipe", stderr: "ignore", stdin: "ignore" });
  const output = (await new Response(child.stdout).text()).trim();
  if (await child.exited !== 0 || !output) throw new Error(`${executable} --version failed`);
  return output.split(/\s+/).at(-1)!;
}

export function approvalArguments(approval: Approval): string[] {
  if (approval === "approve") return ["--approve"];
  if (approval === "no-approve") return ["--no-approve"];
  return [];
}

type Pending = { command: string; resolve: (data: unknown) => void; reject: (error: Error) => void };

export class PiProcess {
  readonly pid: number;
  readonly exited: Promise<PiExit>;
  private readonly child: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private readonly pending = new Map<string, Pending>();
  private sequence = 0;
  private stderrTail = "";
  private shutdownRequested = false;
  private exitResult?: PiExit;
  private readonly onRecord: (record: PiRecord) => void;

  constructor(
    executable: string,
    args: string[],
    options: { cwd: string; env?: Record<string, string>; label: string },
    onRecord: (record: PiRecord) => void,
  ) {
    this.onRecord = onRecord;
    this.child = Bun.spawn({
      cmd: [executable, "--mode", "rpc", ...args],
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    this.pid = this.child.pid;
    agentLog("pi.spawn", { pid: this.pid, label: options.label });
    const output = this.readRecords(this.child.stdout);
    const diagnostics = this.readStderr(this.child.stderr);
    this.exited = this.child.exited.then(async (code) => {
      await Promise.allSettled([output, diagnostics]);
      const exit = { code, requested: this.shutdownRequested, stderr: this.stderrTail.trim() };
      this.exitResult = exit;
      this.rejectPending(exitMessage(exit));
      agentLog("pi.exit", { pid: this.pid, label: options.label, code, requested: exit.requested });
      return exit;
    });
  }

  get alive(): boolean { return this.exitResult === undefined; }

  command<T = unknown>(type: string, fields: Record<string, unknown> = {}): Promise<T> {
    if (this.exitResult) return Promise.reject(new Error(exitMessage(this.exitResult)));
    const id = `ox-${++this.sequence}`;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { command: type, resolve: resolve as (data: unknown) => void, reject });
      try { this.write({ ...fields, id, type }); }
      catch (error) {
        this.pending.delete(id);
        reject(error as Error);
      }
    });
  }

  write(record: Record<string, unknown>): void {
    this.child.stdin.write(`${JSON.stringify(record)}\n`);
    this.child.stdin.flush();
  }

  async shutdown(): Promise<PiExit> {
    if (!this.shutdownRequested && this.alive) {
      this.shutdownRequested = true;
      try { this.child.stdin.end(); } catch {}
      const escalate = setTimeout(() => this.child.kill("SIGTERM"), SHUTDOWN_GRACE_MS);
      const force = setTimeout(() => this.child.kill("SIGKILL"), SHUTDOWN_GRACE_MS * 2);
      void this.exited.finally(() => { clearTimeout(escalate); clearTimeout(force); });
    }
    return this.exited;
  }

  private receive(line: string): void {
    let record: unknown;
    try { record = JSON.parse(line); }
    catch {
      agentLog("pi.malformed", { pid: this.pid, bytes: line.length });
      return;
    }
    if (!record || typeof record !== "object" || Array.isArray(record)) return;
    const value = record as PiRecord;
    if (value.type === "response") this.respond(value);
    else this.onRecord(value);
  }

  private respond(record: PiRecord): void {
    const id = typeof record.id === "string" ? record.id : undefined;
    const pending = id ? this.pending.get(id) : undefined;
    if (!id || !pending) {
      agentLog("pi.unmatched_response", { pid: this.pid, command: String(record.command), success: record.success === true });
      return;
    }
    this.pending.delete(id);
    if (record.success === true) pending.resolve(record.data);
    else pending.reject(new Error(typeof record.error === "string" ? record.error : `pi ${pending.command} failed`));
  }

  private rejectPending(message: string): void {
    for (const pending of this.pending.values()) pending.reject(new Error(message));
    this.pending.clear();
  }

  private async readRecords(stream: ReadableStream<Uint8Array>): Promise<void> {
    const decoder = new TextDecoder();
    let partial: Uint8Array[] = [];
    for await (const chunk of stream) {
      let start = 0;
      for (let newline = chunk.indexOf(10); newline !== -1; newline = chunk.indexOf(10, start)) {
        const bytes = joinBytes([...partial, chunk.subarray(start, newline)]);
        partial = [];
        start = newline + 1;
        const end = bytes.length > 0 && bytes[bytes.length - 1] === 13 ? bytes.length - 1 : bytes.length;
        if (end > 0) this.receive(decoder.decode(bytes.subarray(0, end)));
      }
      if (start < chunk.length) partial.push(chunk.slice(start));
    }
  }

  private async readStderr(stream: ReadableStream<Uint8Array>): Promise<void> {
    const decoder = new TextDecoder();
    for await (const chunk of stream) {
      this.stderrTail = (this.stderrTail + decoder.decode(chunk, { stream: true })).slice(-STDERR_TAIL_BYTES);
    }
  }
}

function joinBytes(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 1) return parts[0]!;
  const joined = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

export function exitMessage(exit: PiExit): string {
  const status = exit.code === null ? "pi exited" : `pi exited with code ${exit.code}`;
  return exit.stderr ? `${status}: ${exit.stderr}` : status;
}
