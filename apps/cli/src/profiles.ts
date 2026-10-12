import { readFileSync } from "node:fs";
import { PROFILE_COMMANDS as DISK_COMMANDS } from "./ox-content.ts";
import { type CliContext, type SubCommand } from "./lib.ts";
import { adminArgs, adminCall, printAdminResult } from "./host-admin.ts";

function hostMode(context: CliContext) {
  return !!context.host || (!context.profile && !!process.env.OX_HOST_ENDPOINT);
}

async function profileID(args: ReturnType<typeof adminArgs>, context: CliContext): Promise<string> {
  if (args.positionals.length > 1) throw new Error("Supply one Profile ID");
  if (args.positionals[0] && context.profile) throw new Error("Select a Profile by argument or --profile, not both");
  const selected = args.positionals[0] ?? context.profile;
  if (selected) return selected;
  const result = await adminCall("profiles.list", {}, args, context);
  const active = (result.profiles as { id: string; active: boolean }[]).find(profile => profile.active);
  if (!active) throw new Error("The Host has no active Profile");
  return active.id;
}

async function inspect(raw: string[], context: CliContext, document?: "memory" | "soul") {
  const args = adminArgs(raw);
  if (args.values.help) { console.log(`Usage: ox --host <ws-url> [--profile <id>] profile ${document ?? "inspect"} [id] [--json] [--timeout 30000]`); return; }
  const profileId = await profileID(args, context);
  const result = await adminCall("profiles.inspect", { profileId }, args, context);
  if (document && !args.values.json) process.stdout.write(`${result[document] ?? ""}\n`);
  else printAdminResult(result, args.values.json);
}

async function update(raw: string[], context: CliContext, renameOnly = false) {
  const args = adminArgs(raw, ["name", "memory-file", "soul-file"]);
  if (args.values.help) {
    console.log(`Usage: ox [--host <ws-url>] profile ${renameOnly ? "rename [id] --name <name>" : "update [id] [--name <name>] [--memory-file <path>] [--soul-file <path>]"} [--json]`);
    return;
  }
  if (renameOnly && (!args.values.name || args.values["memory-file"] || args.values["soul-file"])) throw new Error("rename requires --name only");
  const params: Record<string, unknown> = { profileId: await profileID(args, context) };
  if (args.values.name !== undefined) params.name = args.values.name;
  for (const field of ["memory", "soul"]) {
    const path = args.values[`${field}-file`];
    if (typeof path === "string") params[field] = readFileSync(path, "utf8");
  }
  if (Object.keys(params).length === 1) throw new Error("Supply --name, --memory-file, or --soul-file");
  printAdminResult(await adminCall("profiles.update", params, args, context), args.values.json);
}

export const PROFILE_COMMANDS: Record<string, SubCommand> = Object.fromEntries(
  Object.entries(DISK_COMMANDS).map(([name, command]) => [name, { ...command, fn: async (args: string[], context: CliContext) => {
    if (hostMode(context)) throw new Error(`Host-backed profile ${name} is unavailable; use --profile <path> without --host for disk inspection`);
    return command.fn(args, context);
  } }]),
);

Object.assign(PROFILE_COMMANDS, {
  list: { desc: "List Host Profiles with --host, or discover iCloud Profiles offline", fn: async (raw: string[], context: CliContext) => {
    if (!hostMode(context)) return DISK_COMMANDS.list!.fn(raw, context);
    const args = adminArgs(raw);
    if (args.values.help) { console.log("Usage: ox --host <ws-url> profile list [--json]"); return; }
    if (args.positionals.length || context.profile) throw new Error("profile list takes no Profile selector");
    printAdminResult(await adminCall("profiles.list", {}, args, context), args.values.json);
  } },
  inspect: { desc: "Inspect a Profile owned by the Host", fn: inspect },
  create: { desc: "Create a local Profile on the Host (--name)", fn: async (raw: string[], context: CliContext) => {
    const args = adminArgs(raw, ["name"]);
    if (args.values.help) { console.log("Usage: ox [--host <ws-url>] profile create --name <name> [--json]"); return; }
    if (args.positionals.length || context.profile || typeof args.values.name !== "string") throw new Error("profile create requires --name and no Profile selector");
    printAdminResult(await adminCall("profiles.create", { name: args.values.name }, args, context), args.values.json);
  } },
  select: { desc: "Select the Host's active Profile", fn: async (raw: string[], context: CliContext) => {
    const args = adminArgs(raw);
    if (args.values.help) { console.log("Usage: ox [--host <ws-url>] profile select <id> [--json]"); return; }
    if (!args.positionals.length && !context.profile) throw new Error("profile select requires a Profile ID");
    printAdminResult(await adminCall("profiles.select", { profileId: await profileID(args, context) }, args, context), args.values.json);
  } },
  rename: { desc: "Rename a Profile owned by the Host (--name)", fn: (raw: string[], context: CliContext) => update(raw, context, true) },
  update: { desc: "Update Host Profile name, memory, or soul", fn: update },
  ...Object.fromEntries(["memory", "soul"].map(document => [document, {
    desc: `Read the Profile's ${document} from disk or the selected Host`,
    fn: (raw: string[], context: CliContext) => hostMode(context)
      ? inspect(raw, context, document as "memory" | "soul") : DISK_COMMANDS[document]!.fn(raw, context),
  }])),
});
