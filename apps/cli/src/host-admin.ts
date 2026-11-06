import { parseArgs } from "node:util";
import { callHost } from "./host-rpc.ts";
import { type CliContext, type SubCommand } from "./lib.ts";

export function adminArgs(args: string[], strings: string[] = []) {
  const parsed = parseArgs({
    args, allowPositionals: true, strict: true,
    options: {
      json: { type: "boolean" }, help: { type: "boolean", short: "h" }, timeout: { type: "string" },
      ...Object.fromEntries(strings.map(name => [name, { type: "string" as const }])),
    },
  });
  const timeout = Number(parsed.values.timeout ?? 30000);
  if (!Number.isFinite(timeout) || timeout <= 0) throw new Error("--timeout must be a positive number");
  const values = parsed.values as typeof parsed.values & Record<string, string | boolean | undefined>;
  return { ...parsed, values, timeout };
}

export async function adminCall(method: string, params: Record<string, unknown>, args: ReturnType<typeof adminArgs>, context: CliContext) {
  if (method.startsWith("files.")) {
    const description = await callHost("host.describe", {}, args.timeout, context.host);
    if (!Array.isArray(description.methods) || !description.methods.includes("files.assign")) {
      throw new Error("Update the Host to a build supporting Profile-bound folder mounts");
    }
  }
  return callHost(method, params, args.timeout, context.host);
}

export function printAdminResult(value: Record<string, unknown>, json: boolean | undefined) {
  const rows = value.profiles ?? value.folders ?? value.repositories;
  if (!json && Array.isArray(rows)) {
    for (const row of rows) console.log(`${row.id}\t${row.name}${row.active ? "\tactive" : ""}${row.state ? `\t${row.state}` : ""}`);
    if (Array.isArray(value.unassignedFolders)) for (const row of value.unassignedFolders) console.log(`${row.id}\t${row.name}\tunassigned`);
  } else console.log(JSON.stringify(value, null, 2));
}

function command(method: string, usage: string, parameter?: string): SubCommand {
  return { desc: usage, fn: async (raw, context) => {
    const args = adminArgs(raw);
    if (args.values.help) { console.log(`Usage: ox [--host <ws-url>] ${usage} [--json] [--timeout 30000]`); return; }
    if (args.positionals.length !== (parameter ? 1 : 0)) throw new Error(`Usage: ox ${usage}`);
    const params: Record<string, unknown> = parameter ? { [parameter]: args.positionals[0] } : {};
    if (method.startsWith("files.") && context.profile) params.profileId = context.profile;
    printAdminResult(await adminCall(method, params, args, context), args.values.json);
  } };
}

export const FILE_COMMANDS = {
  list: command("files.list", "files list"),
  mount: command("files.mount", "files mount"),
  assign: command("files.assign", "files assign <unassigned-grant-id>", "grantId"),
  unmount: command("files.unmount", "files unmount <grant-id>", "grantId"),
};
export const HOST_REPOSITORY_COMMANDS = {
  list: command("repositories.list", "repository list"),
  connect: command("repositories.connectFolder", "repository connect mounts/<grant-id>[/subfolder]", "path"),
  disconnect: command("repositories.disconnectFolder", "repository disconnect <repository-id>", "repositoryId"),
};
