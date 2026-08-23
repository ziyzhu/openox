import { C, dispatch, fail, failResult, printResult, takeFlag, terminalText, type CliContext, type SubCommand } from "./lib.ts";
import { createServiceRuntime } from "./service-runtime.ts";
import { requireRepository, withRepository } from "./repositories.ts";
import { readWebService } from "./service-manifest.ts";

export const SUBS: Record<string, SubCommand> = {
  "list": { desc: "List web services in the selected repository (--json)", fn: listServicesCmd },
  "inspect": { desc: "Print a service's full manifest as JSON", fn: inspectService },
  "actions": { desc: "List actions declared by a service (--json)", fn: listActions },
  "skills": { desc: "List skills declared by a service (--json)", fn: listSkills },
  "test": { desc: "Run fail-closed service action tests from committed cases and HARs", fn: testService },
  "status": { desc: "Show services and their live page state in the selected runtime", fn: status },
  "invoke": { desc: "Invoke a service action in the selected runtime", fn: invoke },
  "eval": { desc: "Run a JS script on a service page in the selected runtime", fn: evaluate },
  "reload": { desc: "Reload a service page after active actions finish", fn: reload },
  "open": { desc: "Open a managed service page in headed Chrome", fn: openService },
  "auth": { desc: "Open a headed sign-in handoff for a service", fn: authenticate },
  "bot-control": { desc: "Open a headed human-verification handoff for a service", fn: botControl },
  "sync": { desc: "Refresh service definitions and invalidate changed live services", fn: syncMonoRepository },
};

export async function service(args: string[], context: CliContext): Promise<void> {
  return dispatch("service", "Inspect services on disk and exercise them in the selected runtime.", SUBS, args, context);
}

async function testService(args: string[], context: CliContext): Promise<void> {
  const command = await import("./service-test.ts");
  await command.testService(args, context);
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
      console.log(`Usage: ox service invoke <domain>:<action> [--args '{}'] [--approve] [--timeout 30000]`);
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

  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.invoke({ domain, action, args: parsedArgs, approved, timeoutMs, sessionId: context.session }), "invoke");
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
      console.log(`Usage: ox service eval <domain> [--script 'return document.title;'] [--timeout 30000]`);
      console.log(`       ${terminalText("script may also be passed as a positional arg after <domain>.", [C.dim])}`);
      return;
    }
    else if (!domain) { domain = a; }
    else if (!script) { script = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");
  if (!script) fail("expected a script (via --script or a positional arg)");

  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.evaluate({ domain, script, timeoutMs, sessionId: context.session }), "eval");
}

async function reload(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox service reload <domain> [--timeout 30000]`);
      return;
    }
    else if (!domain) { domain = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");

  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.reload({ domain, timeoutMs, sessionId: context.session }), "reload");
}

async function openService(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "-s" || a === "--service") { domain = args[++i] ?? ""; }
    else if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log("Usage: ox service open <domain> [--timeout 30000]");
      console.log("       ox service open -s <domain> [--timeout 30000]");
      return;
    }
    else if (!domain) { domain = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");
  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.open({ domain, timeoutMs, sessionId: context.session }), "open");
}

async function authenticate(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let timeoutMs = 300000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 300000; }
    else if (a === "-h" || a === "--help") {
      console.log("Usage: ox service auth <domain> [--timeout 300000]");
      return;
    }
    else if (!domain) { domain = a; }
  }
  if (!domain) fail("expected <domain> (e.g. news.ycombinator.com)");
  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.authenticate({ domain, timeoutMs, sessionId: context.session }), "auth");
}

async function botControl(args: string[], context: CliContext): Promise<void> {
  let domain = "";
  let argsJson = "{}";
  let timeoutMs = 300000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--args") { argsJson = args[++i] ?? "{}"; }
    else if (a === "--timeout") { timeoutMs = Number(args[++i]) || 300000; }
    else if (a === "-h" || a === "--help") {
      console.log("Usage: ox service bot-control <domain> --args '{}' [--timeout 300000]");
      return;
    }
    else if (!domain) { domain = a; }
  }
  if (!domain) fail("expected <domain> (e.g. archive.ph)");
  let parsedArgs: unknown;
  try { parsedArgs = JSON.parse(argsJson); }
  catch (error) { fail(`--args is not valid JSON: ${(error as Error).message}`); }
  if (typeof parsedArgs !== "object" || parsedArgs === null || Array.isArray(parsedArgs)) {
    fail("--args must be a JSON object");
  }
  const runtime = createServiceRuntime(context.runtime, context.repository);
  printResult(await runtime.botControl({
    domain,
    args: parsedArgs as Record<string, unknown>,
    timeoutMs,
    sessionId: context.session,
  }), "bot-control");
}

async function status(args: string[], context: CliContext): Promise<void> {
  let timeoutMs = 30000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 30000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox service status [--timeout 30000]`);
      return;
    }
  }
  const runtime = createServiceRuntime(context.runtime, context.repository);
  const result = await runtime.status(timeoutMs);
  if (result.ok) {
    console.log(JSON.stringify(result.services ?? [], null, 2));
  } else {
    failResult("status", result.error);
  }
}

async function syncMonoRepository(args: string[], context: CliContext): Promise<void> {
  let timeoutMs = 60000;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--timeout") { timeoutMs = Number(args[++i]) || 60000; }
    else if (a === "-h" || a === "--help") {
      console.log(`Usage: ox service sync [--timeout 60000]`);
      console.log(`       ${terminalText("Refreshes the selected runtime and drops cached actions for changed services.", [C.dim])}`);
      return;
    }
  }
  const runtime = createServiceRuntime(context.runtime, context.repository);
  const result = await runtime.sync(timeoutMs);
  if (!result.ok) failResult("sync", result.error);
  const changed = (result.changed as string[] | undefined) ?? [];
  console.log(`${terminalText("synced", [C.bold, C.sky])} head=${String(result.head).slice(0, 12)} services=${result.services}`);
  console.log(changed.length ? `${terminalText("reloaded:", [C.dim])} ${changed.join(", ")}` : terminalText("no service changes", [C.dim]));
}

function takeJsonFlag(args: string[]): { json: boolean; rest: string[] } {
  const rest = args.filter(a => a !== "--json");
  return { json: rest.length !== args.length, rest };
}

function parseServiceFlag(args: string[]): { domain: string; rest: string[] } {
  const { value, rest } = takeFlag(args, "-s", "--service");
  if (!value) fail("missing -s <domain>");
  return { domain: value!, rest };
}

async function loadManifest(domain: string, context: CliContext) {
  return withRepository(requireRepository(context), async (root, repository) => {
    if (!repository.services.includes(`web:${domain}`)) fail(`repository does not contain web:${domain}`);
    return readWebService(root, domain);
  });
}

async function listServicesCmd(rawArgs: string[], context: CliContext): Promise<void> {
  const { json } = takeJsonFlag(rawArgs);
  const rows = await withRepository(requireRepository(context), async (root, repository) => {
    const values: { domain: string; name: string; actions: number }[] = [];
    for (const id of repository.services.filter(service => service.startsWith("web:"))) {
      const domain = id.slice("web:".length);
      const { manifest } = await readWebService(root, domain);
      values.push({ domain, name: manifest.name, actions: manifest.actions.length });
    }
    return values.sort((left, right) => left.domain.localeCompare(right.domain));
  });

  if (json) { process.stdout.write(JSON.stringify(rows, null, 2) + "\n"); return; }

  if (rows.length === 0) { console.log(`\n  (no services found)\n`); return; }
  const w = Math.max(...rows.map(r => r.domain.length));
  console.log("");
  for (const r of rows) {
    console.log(`  ${r.domain.padEnd(w + 4)}${r.name} · ${r.actions} actions`);
  }
  console.log("");
}

async function inspectService(rawArgs: string[], context: CliContext): Promise<void> {
  const { rest } = takeJsonFlag(rawArgs);
  const { domain } = parseServiceFlag(rest);
  const { manifest } = await loadManifest(domain, context);
  process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
}

async function listActions(rawArgs: string[], context: CliContext): Promise<void> {
  const { json, rest } = takeJsonFlag(rawArgs);
  const { domain } = parseServiceFlag(rest);
  const { manifest } = await loadManifest(domain, context);

  const projectAction = (a: { id: string; label?: string; description?: string; baseUrl?: string; requireAuth?: boolean; requireApproval?: boolean }) => ({
    id: a.id,
    label: a.label ?? null,
    description: a.description ?? null,
    separatePage: a.baseUrl != null,
    requireAuth: !!a.requireAuth,
    requireApproval: !!a.requireApproval,
  });

  if (json) {
    const out = {
      domain,
      actions: manifest.actions.map(projectAction),
    };
    process.stdout.write(JSON.stringify(out, null, 2) + "\n");
    return;
  }

  console.log(`\n${manifest.name} (${domain})`);
  console.log(`\n  actions (${manifest.actions.length})`);
  for (const a of manifest.actions) {
    const chips = [
      a.baseUrl ? "[separate-page]" : "",
      a.requireAuth ? "[auth]" : "",
      a.requireApproval ? "[approval]" : "",
    ].filter(Boolean).join(" ");
    const label = a.label ? ` — ${a.label}` : "";
    const tail = chips ? `  ${chips}` : "";
    console.log(`    ${a.id}${label}${tail}`);
  }
  console.log("");
}

async function listSkills(rawArgs: string[], context: CliContext): Promise<void> {
  const { json, rest } = takeJsonFlag(rawArgs);
  const { domain } = parseServiceFlag(rest);
  const { manifest } = await loadManifest(domain, context);
  const skills = manifest.skills ?? [];

  if (json) {
    process.stdout.write(JSON.stringify({ domain, skills }, null, 2) + "\n");
    return;
  }

  console.log(`\n${manifest.name} (${domain})`);
  console.log(`\n  skills (${skills.length})`);
  for (const skill of skills) {
    console.log(`    ${skill.name} — ${skill.description}`);
  }
  console.log("");
}
