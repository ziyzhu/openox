import { C, dispatch, fail, printResult, terminalText, type CliContext, type SubCommand } from "./lib.ts";
import { createHostServiceRuntime } from "./service-runtime.ts";

const HOST_SERVICE_COMMANDS: Record<string, SubCommand> = {
  invoke: { desc: "Invoke a service action through the selected Host", fn: invoke },
  eval: { desc: "Run a JS script on a Host-managed service page", fn: evaluate },
  reload: { desc: "Reload a service page after active actions finish", fn: reload },
  sync: { desc: "Refresh service definitions and invalidate changed live services", fn: syncServices },
};

export async function hostService(args: string[], context: CliContext): Promise<void> {
  return dispatch("host service", "Exercise live services through the selected Host.", HOST_SERVICE_COMMANDS, args, context);
}

async function invoke(args: string[], context: CliContext): Promise<void> {
  let target = "";
  let argsJson = "{}";
  let approved: boolean | undefined;
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--args") { argsJson = args[++i] ?? "{}"; }
    else if (a === "--approve") { approved = true; }
    else if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox host service invoke <domain>:<action> [--args '{}'] [--approve] [--timeout 30000]`);
      return;
    }
    else if (!target) { target = a; }
  }
  const separator = target.lastIndexOf(":");
  if (separator <= 0 || separator === target.length - 1) fail("expected <domain>:<action> (e.g. x.com:search)");
  const domain = target.slice(0, separator);
  const action = target.slice(separator + 1);
  let parsedArgs: unknown;
  try { parsedArgs = JSON.parse(argsJson); }
  catch (e) { fail(`--args is not valid JSON: ${(e as Error).message}`); }

  const host = createHostServiceRuntime(context.host);
  printResult(await host.invoke({ domain, action, args: parsedArgs, approved, timeoutMs }));
}

async function evaluate(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let script = "";
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--script") { script = args[++i] ?? ""; }
    else if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox host service eval <domain> [--script 'return document.title;'] [--timeout 30000]`);
      console.log(`       ${terminalText("script may also be passed as a positional arg after <domain>.", [C.dim])}`);
      return;
    }
    else if (!domain) { domain = a; }
    else if (!script) { script = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");
  if (!script) fail("expected a script (via --script or a positional arg)");

  const host = createHostServiceRuntime(context.host);
  printResult(await host.evaluate({ domain, script, timeoutMs }));
}

async function reload(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox host service reload <domain> [--timeout 30000]`);
      return;
    }
    else if (!domain) { domain = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");

  const host = createHostServiceRuntime(context.host);
  printResult(await host.reload({ domain, timeoutMs }));
}

export async function serviceStatus(args: string[], context: CliContext): Promise<void> {
  let timeoutMs = 30000;
  let json = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "--json") { json = true; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox host services [--json] [--timeout 30000]`);
      return;
    }
  }
  const host = createHostServiceRuntime(context.host);
  const result = await host.status(timeoutMs);
  const services = (result.services ?? []) as Array<Record<string, unknown>>;
  if (json) {
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
  let timeoutMs = 60000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 60000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox host service sync [--timeout 60000]`);
      console.log(`       ${terminalText("Refreshes the selected Host and drops cached actions for changed services.", [C.dim])}`);
      return;
    }
  }
  const host = createHostServiceRuntime(context.host);
  const result = await host.sync(timeoutMs);
  const changed = (result.changed as string[] | undefined) ?? [];
  console.log(`${terminalText("synced", [C.bold, C.sky])} head=${String(result.head).slice(0, 12)} services=${result.services}`);
  console.log(changed.length ? `${terminalText("reloaded:", [C.dim])} ${changed.join(", ")}` : terminalText("no service changes", [C.dim]));
}
