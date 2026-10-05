import { fail, type CliContext, type SubCommand } from "./lib.ts";
import { requireRepository, withRepository } from "./repositories.ts";
import { readWebService } from "./service-manifest.ts";
import { printSkills } from "./ox-content.ts";

export const REPOSITORY_SERVICE_COMMANDS: Record<string, SubCommand> = {
  services: { desc: "List the repository's web and API services, or print one manifest as JSON", fn: services },
  actions: { desc: "List the actions a repository service declares (--json)", fn: actions },
  skills: { desc: "List the repository's skills, or print one", fn: skills },
};

function parseArgs(args: string[], usage: string): { json: boolean; domain?: string } {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(`Usage: ${usage}`);
    process.exit(0);
  }
  const positional = args.filter(argument => argument !== "--json");
  const unknown = positional.find(argument => argument.startsWith("-"));
  if (unknown) fail(`unknown option: ${unknown}`);
  if (positional.length > 1) fail("expected at most one service domain");
  return { json: positional.length !== args.length, domain: positional[0] };
}

async function loadManifest(domain: string, context: CliContext) {
  return withRepository(requireRepository(context), async (root, repository) => {
    if (!repository.services.includes(`web:${domain}`) && !repository.services.includes(`api:${domain}`)) fail(`repository does not contain service ${domain}`);
    return readWebService(root, domain);
  });
}

async function services(args: string[], context: CliContext): Promise<void> {
  const { json, domain } = parseArgs(args, "ox --repository <path-or-url> repository services [domain] [--json]");
  if (domain) {
    const { manifest } = await loadManifest(domain, context);
    process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
    return;
  }
  const rows = await withRepository(requireRepository(context), async (root, repository) => {
    const values: { domain: string; name: string; actions: number }[] = [];
    for (const id of repository.services.filter(service => service.startsWith("web:") || service.startsWith("api:"))) {
      const serviceDomain = id.slice("web:".length);
      const { manifest } = await readWebService(root, serviceDomain);
      values.push({ domain: serviceDomain, name: manifest.name, actions: manifest.actions.length });
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

async function actions(args: string[], context: CliContext): Promise<void> {
  const { json, domain } = parseArgs(args, "ox --repository <path-or-url> repository actions <domain> [--json]");
  if (!domain) fail("repository actions requires a service domain");
  const { manifest } = await loadManifest(domain!, context);
  const projectAction = (a: { id: string; label?: string; description?: string; baseUrl?: string; requireAuth?: boolean; requireApproval?: boolean }) => ({
    id: a.id,
    label: a.label ?? null,
    description: a.description ?? null,
    separatePage: a.baseUrl != null,
    requireAuth: !!a.requireAuth,
    requireApproval: !!a.requireApproval,
  });
  if (json) {
    process.stdout.write(JSON.stringify({ domain, actions: manifest.actions.map(projectAction) }, null, 2) + "\n");
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

async function skills(args: string[], context: CliContext): Promise<void> {
  await printSkills(args, "ox --repository <path-or-url> repository skills [name] [--json]", (print) =>
    withRepository(requireRepository(context), async (root, repository) => print(root, repository.skills)));
}
