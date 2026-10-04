import { readFile } from "node:fs/promises";
import { parseArgs, type ParseArgsOptionsConfig } from "node:util";
import { C, dispatch, fail, printResult, terminalText, type CliContext, type SubCommand } from "./lib.ts";
import { createHostServiceRuntime } from "./service-runtime.ts";

const HOST_SERVICE_COMMANDS: Record<string, SubCommand> = {
  invoke: { desc: "Invoke a service action through the selected Host", fn: invoke },
  eval: { desc: "Run a JS script on a Host-managed service page", fn: evaluate },
  reload: { desc: "Reload a service page after active actions finish", fn: reload },
  "refresh-auth": { desc: "Recheck a service's authentication state", fn: refreshAuth },
  sync: { desc: "Refresh service definitions and invalidate changed live services", fn: syncServices },
};

export async function hostService(args: string[], context: CliContext): Promise<void> {
  return dispatch("host service", "Exercise live services through the selected Host.", HOST_SERVICE_COMMANDS, args, context);
}

function options(args: string[], usage: string, config: ParseArgsOptionsConfig = {}, maximumPositionals = 0, defaultTimeout = 30000) {
  const { values, positionals } = parseArgs({
    args, strict: true, allowPositionals: true,
    options: { ...config, timeout: { type: "string" }, json: { type: "boolean" }, help: { type: "boolean", short: "h" } },
  });
  if (values.help) {
    console.log(`Usage: ox ${usage} [--json] [--timeout ${defaultTimeout}]`);
    return null;
  }
  if (positionals.length > maximumPositionals) fail(`unexpected argument: ${positionals[maximumPositionals]}`);
  const timeoutMs = values.timeout === undefined ? defaultTimeout : Number(values.timeout);
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) fail("--timeout requires a positive number");
  return { values: values as Record<string, string | boolean | undefined>, positionals, timeoutMs };
}

async function inputText(path: string): Promise<string> {
  return path === "-" ? Bun.stdin.text() : readFile(path, "utf8");
}

async function invoke(args: string[], context: CliContext): Promise<void> {
  const parsed = options(args, "host service invoke <domain>:<action> [--args '{}'] [--args-file <path|->] [--approve]", {
    args: { type: "string" }, "args-file": { type: "string" }, approve: { type: "boolean" },
  }, 1);
  if (!parsed) return;
  const { values, positionals, timeoutMs } = parsed;
  const target = positionals[0] ?? "";
  const separator = target.lastIndexOf(":");
  if (separator <= 0 || separator === target.length - 1) fail("expected <domain>:<action> (e.g. x.com:search)");
  if (values.args !== undefined && values["args-file"] !== undefined) fail("use either --args or --args-file, not both");
  const raw = values["args-file"] !== undefined ? await inputText(String(values["args-file"])) : String(values.args ?? "{}");
  let actionArgs: unknown;
  try { actionArgs = JSON.parse(raw); }
  catch (error) { fail(`invalid action arguments JSON: ${(error as Error).message}`); }
  const host = createHostServiceRuntime(context.host);
  printResult(await host.invoke({ domain: target.slice(0, separator), action: target.slice(separator + 1),
    args: actionArgs, approved: values.approve === true ? true : undefined, timeoutMs }));
}

async function evaluate(args: string[], context: CliContext): Promise<void> {
  const parsed = options(args, "host service eval <domain> [<script> | --script <javascript> | --script-file <path|->]", {
    script: { type: "string" }, "script-file": { type: "string" },
  }, 2);
  if (!parsed) return;
  const { values, positionals, timeoutMs } = parsed;
  const domain = positionals[0] ?? fail("expected <domain>");
  const sources = [values.script, values["script-file"], positionals[1]].filter(value => value !== undefined);
  if (sources.length !== 1) fail("provide exactly one script or script file");
  const script = values["script-file"] !== undefined ? await inputText(String(values["script-file"])) : String(values.script ?? positionals[1]);
  if (!script.trim()) fail("script must not be empty");
  printResult(await createHostServiceRuntime(context.host).evaluate({ domain, script, timeoutMs }));
}

async function serviceOperation(args: string[], context: CliContext, operation: "reload" | "refreshAuth") {
  const name = operation === "reload" ? "reload" : "refresh-auth";
  const parsed = options(args, `host service ${name} <domain>`, {}, 1);
  if (!parsed) return;
  const domain = parsed.positionals[0] ?? fail("expected <domain>");
  printResult(await createHostServiceRuntime(context.host)[operation]({ domain, timeoutMs: parsed.timeoutMs }));
}

async function reload(args: string[], context: CliContext): Promise<void> {
  await serviceOperation(args, context, "reload");
}

async function refreshAuth(args: string[], context: CliContext): Promise<void> {
  await serviceOperation(args, context, "refreshAuth");
}

export async function serviceStatus(args: string[], context: CliContext): Promise<void> {
  const parsed = options(args, "host services");
  if (!parsed) return;
  const result = await createHostServiceRuntime(context.host).status(parsed.timeoutMs);
  const services = (result.services ?? []) as Array<Record<string, unknown>>;
  if (parsed.values.json) {
    console.log(JSON.stringify(services, null, 2));
    return;
  }
  if (!services.length) {
    console.log("(no services)");
    return;
  }
  const width = Math.max(...services.map(service => String(service.domain ?? "").length));
  for (const service of services) {
    const domain = String(service.domain ?? "");
    const phase = String(service.phase ?? "unknown");
    const signIn = String(service.signIn ?? "unknown");
    const pages = Number(service.pageCount ?? 0);
    const active = Number(service.activeInvocations ?? 0);
    const queued = Number(service.queuedInvocations ?? 0);
    console.log(`${domain.padEnd(width + 2)}${phase} · auth ${signIn} · pages ${pages} · actions ${active} active/${queued} queued`);
  }
}

async function syncServices(args: string[], context: CliContext): Promise<void> {
  const parsed = options(args, "host service sync", {}, 0, 60000);
  if (!parsed) return;
  const result = await createHostServiceRuntime(context.host).sync(parsed.timeoutMs);
  if (parsed.values.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  const changed = (result.changed as string[] | undefined) ?? [];
  console.log(`${terminalText("synced", [C.bold, C.sky])} head=${String(result.head).slice(0, 12)} services=${result.services}`);
  console.log(changed.length ? `${terminalText("reloaded:", [C.dim])} ${changed.join(", ")}` : terminalText("no service changes", [C.dim]));
}
