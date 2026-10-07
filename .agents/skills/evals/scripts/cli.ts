import { ROOT } from "../../../lib.ts";

export async function ox<T>(host: string, args: string[], chatId?: string, timeoutMs = 10_000, allowOutcome = false): Promise<T> {
  const child = Bun.spawn([process.execPath, "--no-env-file", `${ROOT}/apps/cli/src/ox.ts`,
    "--host", host, ...(chatId ? ["--chat", chatId] : []), ...args, "--json", "--timeout", String(timeoutMs)], {
    cwd: ROOT, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs + 2_000);
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    if (code !== 0 && !allowOutcome) throw new Error(stderr.trim() || `ox ${args.slice(0, 2).join(" ")} exited ${code}`);
    try { return JSON.parse(stdout) as T; }
    catch { throw new Error(stderr.trim() || "Ox CLI did not return JSON; request may have been submitted, not retrying"); }
  } finally { clearTimeout(timer); }
}

export async function vmCall<T>(host: string, chatId: string, name: string, args: Record<string, unknown>, timeoutMs: number): Promise<T> {
  const result = await ox<{ value: T }>(host, ["vm", "call", name, "--args", JSON.stringify({ purpose: "Observe eval state", ...args })], chatId, timeoutMs);
  if (result.value === undefined || result.value === null) throw new Error(`Missing observation from ${name}`);
  return result.value;
}

export async function newChat(host: string, provider: string, model: string, temporary: boolean, timeoutMs: number): Promise<string> {
  const result = await ox<{ chatId: string; temporary: boolean; model: string }>(host,
    ["chat", "new", ...(temporary ? ["--temporary"] : []), "--provider", provider, "--model", model], undefined, timeoutMs);
  if (!result.chatId || result.temporary !== temporary || result.model !== `${provider}:${model}`) throw new Error("Unexpected new chat identity, mode, or model");
  return result.chatId;
}
