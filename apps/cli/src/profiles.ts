import { readFileSync } from "node:fs";
import { PROFILE_COMMANDS as DISK_COMMANDS } from "./ox-content.ts";
import { type CliContext, type SubCommand } from "./lib.ts";
import { adminArgs, adminCall, printAdminResult } from "./profile-admin.ts";
import { ProfileRPCClient } from "./profile-rpc.ts";
import { ENVIRONMENT_ENDPOINT } from "./profile-connection.ts";
import { LIVE_PROFILE_COMMANDS } from "./profile-live.ts";

function liveMode(context: CliContext) {
  return !!context.endpoint || (!context.profile && !!ENVIRONMENT_ENDPOINT);
}

async function openProfileID(args: ReturnType<typeof adminArgs>, context: CliContext): Promise<string> {
  if (args.positionals.length) throw new Error("Commands on an open Profile take no Profile ID; connect to the Profile with --profile <ws-url>");
  const client = new ProfileRPCClient(context.endpoint);
  try {
    const profile = (await client.describe(args.timeout)).profile;
    if (!profile) throw new Error("Ox has no open Profile");
    return profile.id;
  } finally {
    client.close();
  }
}

async function inspect(raw: string[], context: CliContext, document?: "memory") {
  const args = adminArgs(raw);
  if (args.values.help) { console.log(`Usage: ox [--profile <ws-url>] profile ${document ?? "inspect"} [--json] [--timeout 30000]`); return; }
  const profileId = await openProfileID(args, context);
  const result = await adminCall("profiles.inspect", { profileId }, args, context);
  if (document && !args.values.json) process.stdout.write(`${result[document] ?? ""}\n`);
  else printAdminResult(result, args.values.json);
}

async function update(raw: string[], context: CliContext, renameOnly = false) {
  const args = adminArgs(raw, ["name", "memory-file"]);
  if (args.values.help) {
    console.log(`Usage: ox [--profile <ws-url>] profile ${renameOnly ? "rename --name <name>" : "update [--name <name>] [--memory-file <path>]"} [--json]`);
    return;
  }
  if (renameOnly && (!args.values.name || args.values["memory-file"])) throw new Error("rename requires --name only");
  const params: Record<string, unknown> = { profileId: await openProfileID(args, context) };
  if (args.values.name !== undefined) params.name = args.values.name;
  const memoryFile = args.values["memory-file"];
  if (typeof memoryFile === "string") params.memory = readFileSync(memoryFile, "utf8");
  if (Object.keys(params).length === 1) throw new Error("Supply --name or --memory-file");
  printAdminResult(await adminCall("profiles.update", params, args, context), args.values.json);
}

function diskOnly(name: string, command: SubCommand): SubCommand {
  return { ...command, fn: async (args: string[], context: CliContext) => {
    if (liveMode(context)) throw new Error(`profile ${name} reads a Profile folder; use --profile <path> and unset OX_PROFILE_ENDPOINT`);
    return command.fn(args, context);
  } };
}

export const PROFILE_COMMANDS: Record<string, SubCommand> = {
  ...Object.fromEntries(Object.entries(DISK_COMMANDS).map(([name, command]) => [name, diskOnly(name, command)])),
  ...LIVE_PROFILE_COMMANDS,
  inspect: { desc: "Inspect the open Profile", fn: inspect },
  rename: { desc: "Rename the open Profile (--name)", fn: (raw: string[], context: CliContext) => update(raw, context, true) },
  update: { desc: "Update the open Profile's name or memory", fn: update },
  memory: {
    desc: "Read the Profile's memory from the open Profile or a Profile folder",
    fn: (raw: string[], context: CliContext) => liveMode(context) ? inspect(raw, context, "memory") : DISK_COMMANDS.memory!.fn(raw, context),
  },
};
