import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { iosTarget } from "../../../setup/scripts/ios.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireFreePort, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { cases } from "./cases.ts";
import { harness } from "./harness.ts";
import { startFixtures } from "./server.ts";
import { card } from "./sites/card.ts";
import { chat } from "./sites/chat.ts";
import { gov } from "./sites/gov.ts";
import { gql } from "./sites/gql.ts";
import { ssr } from "./sites/ssr.ts";
import { suite } from "./sites/suite.ts";

const usage = `Usage: bun run test:web --device ox-N [--app <Ox.app>] [--case <name>] [--keep-booted]
Runs website service fixtures against a Debug Simulator build on a reserved QA simulator.
Applies a run-owned template Profile, trusts the fixture CA on that simulator only, serves the
fixture repository on the device's repository port, and shuts the simulator down afterwards
unless it was already booted or --keep-booted is passed. Builds the app when --app is omitted.`;

const config = qaCommand({ usage, options: { app: { type: "string" }, case: { type: "string" }, "keep-booted": { type: "boolean" } } });
const values = config.values as { app?: string; case?: string; "keep-booted"?: boolean };
const sites = [ssr, chat, gql, suite, card, gov];
const selected = cases.filter(entry => !values.case || entry.name === values.case || entry.site === values.case);
if (!selected.length) throw new Error(`No case matches ${values.case}`);

const bundle = /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(await Bun.file(join(ROOT, "apps/ios/Local.xcconfig")).text().catch(() => ""))?.[1];
if (!bundle) throw new Error("Configure OX_BUNDLE_IDENTIFIER in apps/ios/Local.xcconfig");
const evidence = await mkdtemp(join(tmpdir(), "ox-web-fixtures-run-"));
const ios = iosTarget(config.device);
const wasBooted = await requireSimulator(config.device);
for (const port of [config.registryPort, config.fixturePort]) await requireFreePort(port);
const app = values.app ? resolve(values.app) : await ios.build(join(evidence, "DerivedData"), join(evidence, "build.log"));

const template = join(evidence, "template.json");
await writeFile(template, JSON.stringify({
  version: 1,
  settings: { language: "en", onboardingCompleted: true, allowHostConnections: true, defaultModel: { provider: "mock", model: "mock" } },
  profiles: [{ id: "web", name: "Web Fixtures", conversations: [{ id: "fixtures", title: "Web fixtures", model: { provider: "mock", model: "mock" },
    messages: [{ role: "user", text: "Web fixture run." }, { role: "assistant", text: "Ready." }] }] }],
  selection: { profile: "web", conversation: "fixtures" },
}));
await run(["bun", ".agents/skills/setup/scripts/template.ts", "--device", config.device, "--template", template, "--app", app, "--loopback", "--output", evidence], { capture: true });

const release = claimSimulator(config.device);
const fixtures = await startFixtures(sites, config.fixturePort);
const repository = Bun.spawn(["bun", "apps/cli/src/ox.ts", "--repository", fixtures.repository, "repository", "serve", "--port", String(config.registryPort)],
  { cwd: ROOT, stdout: Bun.file(join(evidence, "repository.log")), stderr: "inherit" });
const results: Array<{ name: string; status: "pass" | "fail"; detail: string }> = [];
try {
  const udid = await ios.udid();
  await run(["xcrun", "simctl", "keychain", udid, "add-root-cert", fixtures.ca], { capture: true });
  for (let attempt = 0; !(await fetch(`http://127.0.0.1:${config.registryPort}/health`).then(response => response.ok, () => false)); attempt++) {
    if (attempt > 50) throw new Error("Fixture repository did not start");
    await Bun.sleep(100);
  }
  await run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle], {
    capture: true, env: {
      SIMCTL_CHILD_OX_HOST_LOOPBACK: "1", SIMCTL_CHILD_OX_DEBUG_ENDPOINT: config.debugEndpoint,
      SIMCTL_CHILD_OX_SERVICES_ENDPOINT: `http://localhost:${config.registryPort}/repository.git`,
    },
  });
  const h = harness({ device: config.device, debugEndpoint: config.debugEndpoint, fixtures, sites, evidence });
  for (let attempt = 0; ; attempt++) {
    const synced = await h.ox(["service", "sync"], { allowFailure: true });
    if (!synced.error) break;
    if (attempt > 60) throw new Error(`Host did not become available: ${synced.error}`);
    await Bun.sleep(500);
  }
  const loaded = new Set((await h.ox(["service", "list"]) as Array<{ domain: string }>).map(service => service.domain));
  const missing = sites.flatMap(site => site.services(fixtures.origin).map(service => service.manifest.domain)).filter(domain => !loaded.has(domain));
  if (missing.length) throw new Error(`Fixture services did not load: ${missing.join(", ")}`);
  for (const entry of selected) {
    fixtures.reset();
    await h.newConversation();
    try {
      results.push({ name: entry.name, status: "pass", detail: await entry.run(h) });
    } catch (error) {
      await h.screenshot(`${entry.name}-failure`).catch(() => {});
      await ios.describe().then(tree => writeFile(join(evidence, `${entry.name}-failure-accessibility.json`), JSON.stringify(tree)), () => {});
      results.push({ name: entry.name, status: "fail", detail: (error as Error).message.replace(/\s+/g, " ").slice(0, 600) });
    }
    await h.forgetLogins().catch(error => console.error(`Saved login cleanup failed: ${(error as Error).message}`));
    console.log(`${results.at(-1)!.status.toUpperCase()} ${entry.name}: ${results.at(-1)!.detail}`);
  }
} finally {
  repository.kill();
  fixtures.stop();
  await run(["xcrun", "simctl", "terminate", await ios.udid(), bundle], { capture: true, allowFailure: true });
  if (!wasBooted && !values["keep-booted"]) await ios.shutdown().catch(() => {});
  release();
  await writeFile(join(evidence, "results.json"), JSON.stringify({ device: config.device, app, results }, null, 2));
  console.log(`Evidence: ${evidence}`);
}
if (results.some(result => result.status === "fail")) process.exit(1);
