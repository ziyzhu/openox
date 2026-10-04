import { relative, resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");

type RunOptions = {
  capture?: boolean;
  allowFailure?: boolean;
  cwd?: string;
  env?: Record<string, string | undefined>;
};

type RunResult = { code: number; stdout: string; stderr: string };

const children = new Set<ReturnType<typeof Bun.spawn>>();

export function killChildren(signal: NodeJS.Signals): void {
  for (const child of children) child.kill(signal);
}

export async function run(cmd: string[], options: RunOptions = {}): Promise<RunResult> {
  const output = options.capture ? "pipe" : "inherit";
  const child = Bun.spawn({
    cmd,
    cwd: options.cwd ?? ROOT,
    env: options.env ? { ...Bun.env, ...options.env } : undefined,
    stdout: output,
    stderr: output,
  });
  children.add(child);
  const [code, stdout, stderr] = await Promise.all([
    child.exited.finally(() => children.delete(child)),
    options.capture ? new Response(child.stdout as ReadableStream).text() : "",
    options.capture ? new Response(child.stderr as ReadableStream).text() : "",
  ]);
  if (code !== 0 && !options.allowFailure) {
    const detail = (stderr || stdout).trim();
    throw new Error(`${cmd.join(" ")} exited ${code}${detail ? `: ${detail}` : ""}`);
  }
  return { code, stdout, stderr };
}

export type Check = () => Promise<string>;

export async function runCheck(check: Check): Promise<void> {
  console.log(`PASS ${await check()}`);
}

export type Generated = Record<string, string>;

export async function writeGenerated(files: Generated): Promise<void> {
  for (const [path, contents] of Object.entries(files)) await Bun.write(path, contents);
}

export async function checkGenerated(files: Generated, command: string): Promise<void> {
  const stale: string[] = [];
  for (const [path, contents] of Object.entries(files)) {
    const file = Bun.file(path);
    if (!await file.exists() || await file.text() !== contents) stale.push(relative(ROOT, path));
  }
  if (stale.length > 0) throw new Error(`Generated files are stale. Run bun run ${command}:\n${stale.join("\n")}`);
}
