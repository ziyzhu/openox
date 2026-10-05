import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../lib.ts";
import { qaCommand } from "./qa-config.ts";
import { claimSimulator, requireFreePort, requireSimulator } from "./simulator.ts";

const config = qaCommand({
  usage: "Usage: bun run test:conversation --device ox-N\nRuns the DEBUG Simulator website-conversation E2E fixture; no provider credentials or live website submissions.",
});
const bundle = "ai.oxcraft.bot";
const receipt = "Library/Caches/WebConversationFixture/result.json";
const directory = await mkdtemp(join(tmpdir(), "ox-web-conversation-"));
const release = claimSimulator(config.device);
const effects: string[] = [];
let server: ReturnType<typeof Bun.serve> | undefined;
let launched = false;
const launch = ["sim", "--device", config.device, "run", bundle,
  "--project", "apps/ios/Ox.xcodeproj", "--scheme", "ios", "--env", `OX_DEBUG_ENDPOINT=${config.debugEndpoint}`];
try {
  if (!await requireSimulator(config.device)) await run(["sim", "devices", "boot", config.device]);
  await requireFreePort(config.registryPort);
  server = Bun.serve({
    hostname: "127.0.0.1", port: config.registryPort,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/conversation-fixture" && request.method === "GET") {
        if (url.searchParams.has("slow-load")) await Bun.sleep(1000);
        return new Response("<!doctype html><html><body>OpenOx synthetic conversation fixture</body></html>", { headers: { "content-type": "text/html" } });
      }
      if (url.pathname === "/submit" && request.method === "POST") {
        effects.push(await request.text());
        return Response.json({ accepted: true });
      }
      return new Response("Unmatched fixture request", { status: 404 });
    },
  });
  // Remove the previous receipt so a failed launch cannot look like a passing run.
  try { await run(["sim", "--device", config.device, "file", "delete", bundle, receipt], { capture: true }); } catch {}
  await run([...launch, "--force", "--env", `OX_WEB_CONVERSATION_FIXTURE_URL=http://127.0.0.1:${config.registryPort}/conversation-fixture`], { capture: true });
  launched = true;
  const localReceipt = join(directory, "result.json");
  const deadline = Date.now() + 90_000;
  let pulled = false;
  while (Date.now() < deadline) {
    try {
      await run(["sim", "--device", config.device, "file", "pull", bundle, receipt, "--dest", directory], { capture: true });
      pulled = true;
      break;
    } catch { await Bun.sleep(1000); }
  }
  if (!pulled) throw new Error(`Fixture did not produce a receipt. Diagnostics directory: ${directory}`);
  const result = await Bun.file(localReceipt).json() as { passed: boolean; checks: string[]; error: string | null };
  await Bun.write(join(directory, "effects.json"), JSON.stringify(effects, null, 2));
  if (!result.passed) throw new Error(`${result.error}\nDiagnostics: ${directory}`);
  if (effects.length !== 14 || effects.filter(text => text === "uncertain-throw").length !== 1 || effects.includes("denied") || effects.includes("busy") || effects.includes("changed") || effects.includes("changed-account") || effects.includes("closed-during-open")) {
    throw new Error(`Unexpected submission effects: ${JSON.stringify(effects)}\nDiagnostics: ${directory}`);
  }
  console.log(JSON.stringify({ ...result, effects: effects.length, diagnostics: directory }, null, 2));
} finally {
  server?.stop(true);
  try {
    if (launched) await run(launch, { capture: true }); // Restore launch state without the fixture environment.
  } finally { release(); }
}
