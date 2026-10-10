import { open, realpath, rm } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { callHost } from "../../../../apps/cli/src/host-rpc.ts";
import { ROOT } from "../../../lib.ts";
import { qaCommand } from "./qa-config.ts";
import { claimSimulator, requireSimulator } from "./simulator.ts";

try {
  const qa = qaCommand({
    usage: "Usage: bun run sim:website-export --device ox-N --output /private/path/session.snapshot [--host <ws-url>]\nExports cookies/local storage from a running authorized Debug Host. Keep credential-bearing snapshots outside Git.",
    options: { output: { type: "string" }, host: { type: "string" } },
  });
  if (!qa.values.device || !qa.values.output) throw new Error("Pass --device and --output explicitly");
  const path = resolve(qa.values.output);
  const parent = await realpath(dirname(path));
  const suffix = relative(await realpath(ROOT), parent);
  if (!suffix || suffix !== ".." && !suffix.startsWith("../") && !isAbsolute(suffix)) throw new Error("Store website sessions outside the repository");
  const endpoint = qa.values.host ?? qa.debugEndpoint;
  const url = new URL(endpoint);
  if (!["ws:", "wss:"].includes(url.protocol) || Number(url.port) !== qa.debugPort || url.username || url.password) throw new Error("Use this device's authorized Host on its assigned port");
  const release = claimSimulator(qa.device);
  try {
    if (!await requireSimulator(qa.device)) throw new Error("Launch the source simulator and enable authorized Host access first");
    const descriptor = await open(path, "wx", 0o600);
    let completed = false;
    try {
      const result = await callHost("debug.websiteData.export", {}, 60_000, endpoint);
      if (typeof result.data !== "string" || typeof result.bytes !== "number") throw new Error("Invalid website snapshot response");
      const bytes = Buffer.from(result.data, "base64");
      if (bytes.length !== result.bytes) throw new Error("Incomplete website snapshot response");
      await descriptor.writeFile(bytes);
      completed = true;
      console.log(`EXPORTED website cookies/local storage (${bytes.length} bytes); authentication must be verified after restoration`);
    } finally {
      await descriptor.close();
      if (!completed) await rm(path, { force: true });
    }
  } finally { release(); }
} catch (error) {
  console.error(`error: ${(error as Error).message}`);
  process.exitCode = 1;
}
