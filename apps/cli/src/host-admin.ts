import { parseArgs } from "node:util";
import { callHost } from "./host-rpc.ts";
import { type CliContext, type SubCommand, dispatch } from "./lib.ts";

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

const FILE_COMMANDS = {
  list: command("files.list", "host files list"),
  mount: command("files.mount", "host files mount"),
  assign: command("files.assign", "host files assign <unassigned-grant-id>", "grantId"),
  unmount: command("files.unmount", "host files unmount <grant-id>", "grantId"),
};
const REPOSITORY_COMMANDS = {
  list: command("repositories.list", "host repository list"),
  connect: command("repositories.connectFolder", "host repository connect files/<grant-id>[/subfolder]", "path"),
  disconnect: command("repositories.disconnectFolder", "host repository disconnect <repository-id>", "repositoryId"),
};

export const hostFiles: SubCommand = {
  desc: "List, mount, assign, or unmount Profile folders on the Host",
  fn: (args, context) => dispatch("host files", "Authorize folder access on the Host device", FILE_COMMANDS, args, context),
};
export const hostRepositories: SubCommand = {
  desc: "List repositories or connect/disconnect a granted folder",
  fn: (args, context) => dispatch("host repository", "Load services through an existing Files mount", REPOSITORY_COMMANDS, args, context),
};
