import { link, mkdtemp, open, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { callHost, HostRPCClient } from "./host-rpc.ts";
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

const downloadUsage = "files download (<path> | --attachment <id>) --output <local-path>";

async function downloadFile(raw: string[], context: CliContext): Promise<void> {
  const args = adminArgs(raw, ["output", "attachment"]);
  if (args.values.help) {
    console.log(`Usage: ox [--host <ws-url>] [--conversation <id>] ${downloadUsage} [--timeout 30000]`);
    return;
  }
  const { output, attachment } = args.values;
  const path = args.positionals[0];
  if (typeof output !== "string" || !output || args.values.json || args.positionals.length > 1 || Boolean(path) === Boolean(attachment)) {
    throw new Error(`Usage: ox ${downloadUsage}`);
  }
  const params = path ? { path } : { attachmentId: attachment };
  const client = new HostRPCClient(context.host);
  const destination = resolve(output);
  const directory = await mkdtemp(join(dirname(destination), ".ox-download-"));
  const temporary = join(directory, "file");
  try {
    const host = await client.describe(args.timeout);
    if (!host.methods.includes("files.download")) throw new Error("Update the Host to a build supporting file downloads");
    const file = await open(temporary, "wx", 0o600);
    let offset = 0;
    try {
      let transferId: string | undefined;
      let size: number | undefined;
      do {
        const result = await client.call("files.download", args.timeout,
          transferId ? { transferId } : { ...params, conversationId: context.conversation ?? null });
        const { transferId: id, size: bytes, offset: start, data } = result;
        if (typeof id !== "string" || typeof bytes !== "number" || typeof data !== "string" || start !== offset
          || (transferId !== undefined && (id !== transferId || bytes !== size))) {
          throw new Error("Host returned an inconsistent file transfer");
        }
        const chunk = Buffer.from(data, "base64");
        if (chunk.toString("base64") !== data || (chunk.length === 0 && offset < bytes) || offset + chunk.length > bytes) {
          throw new Error("Host returned an invalid file chunk");
        }
        await file.writeFile(chunk);
        offset += chunk.length;
        transferId = id;
        size = bytes;
      } while (offset < size);
    } finally {
      await file.close();
    }
    try { await link(temporary, destination); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`Destination already exists: ${destination}`);
      throw error;
    }
    console.log(`Downloaded ${offset} bytes to ${destination}`);
  } finally {
    client.close();
    await rm(directory, { recursive: true, force: true });
  }
}

export const FILE_COMMANDS = {
  download: { desc: downloadUsage, fn: downloadFile },
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
