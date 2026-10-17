import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../setup/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../setup/scripts/simulator.ts";
import { iosTarget } from "../../../setup/scripts/ios.ts";
import { waitForHost } from "./host.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/image-embed.ts --device ox-N --conversation <saved-Mock-QA-conversation-seeded-with-0> --app /absolute/Ox.app [--bundle id] [--output /tmp/directory]\nUses the assigned loopback Host. Retains run-owned QA files and conversation for visual review; never changes approval policies or credentials.",
  options: { chat: { type: "string" }, app: { type: "string" }, bundle: { type: "string" }, output: { type: "string" } },
});
if (!qa.values.chat || !qa.values.app) throw new Error("Pass a seeded saved QA conversation and the freshly built app");
const localConfig = await readFile(join(ROOT, "apps/ios/Local.xcconfig"), "utf8").catch(() => "");
const bundle = qa.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const directory = resolve(qa.values.output ?? `/tmp/ox-image-embed-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"));
const target = ["ox", "--host", qa.debugEndpoint, "--chat", qa.values.chat];
const imageURL = "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?w=960&h=640&fit=crop";
const checks: string[] = [];
async function json(args: string[]) {
  return JSON.parse((await run(args, { capture: true })).stdout);
}
async function inspect() {
  return json([...target, "conversation", "inspect", "--json"]);
}
async function present(image: string) {
  await json([...target, "conversation", "send", `reply\n![QA image](${image})`, "--json"]);
}
const ios = iosTarget(qa.device);
async function bottom() {
  const tree = await ios.describe();
  if (JSON.stringify(tree).includes('"chat.scrollToBottom"')) {
    await ios.tap({ id: "chat.scrollToBottom" });
    await ios.wait({ id: "chat.scrollToBottom" }, { missing: true, timeout: 5000 });
  }
}
async function screenshot(name: string) {
  await ios.screenshot(join(directory, `${name}.png`));
  await writeFile(join(directory, `${name}-ax.json`), JSON.stringify(await ios.describe()));
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  await json([...target, "conversation", "open", "--json"]);
  const initial = await inspect();
  assert.equal(initial.isBusy, false);
  assert.equal(initial.model.id, "mock");
  assert.equal(initial.messages[0]?.user?.content[0]?.text?.text, "0");
  assert.equal(initial.messages.filter((message: { type: string }) => message.type === "user").length, 1);
  const schema = await json([...target, "vm", "functions", "--json"]);
  assert(!Object.keys(schema).some(name => name.startsWith("ox.artifact.") || name.startsWith("ox.widget.")));
  const retired = await json([...target, "vm", "eval", "--script", "return typeof ox.artifact", "--json"]);
  assert.equal(retired.value, "undefined");
  await present(imageURL);
  await ios.wait({ id: "chat.message.image.open" }, { timeout: 30_000, stable: 300 });
  await screenshot("remote-inline");
  await ios.tap({ id: "chat.message.image.open" });
  await ios.wait({ id: "chat.message.image.close" }, { timeout: 5000, stable: 300 });
  await screenshot("remote-zoom");
  await ios.tap({ id: "chat.message.image.close" });
  checks.push("remote HTTPS image renders inline and opens the zoomable viewer");
  const before = await inspect();
  assert(!before.messages.some((message: unknown) => JSON.stringify(message).includes('"type":"attachment"')));
  await ios.launch(bundle, resolve(qa.values.app), { OX_HOST_LOOPBACK: "1", OX_DEBUG_ENDPOINT: qa.debugEndpoint });
  await waitForHost(qa.debugEndpoint,
    () => json(["ox", "--host", qa.debugEndpoint, "host", "describe", "--timeout", "1000", "--json"]), 10_000);
  await json([...target, "conversation", "open", "--json"]);
  await bottom();
  await ios.wait({ id: "chat.message.image.open" }, { timeout: 30_000, stable: 300 });
  await screenshot("reopened");
  checks.push("remote image embeds survive process relaunch");
  await present("https://openox.ai/qa-image-embed-missing.png");
  await bottom();
  await ios.wait({ id: "chat.message.image.retry" }, { timeout: 30_000, stable: 300 });
  const failures = await json(["ox", "--host", qa.debugEndpoint, "host", "logs", "--grep", "ImageWidgetView.load failed", "--json"]);
  await ios.tap({ id: "chat.message.image.retry" });
  await ios.wait({ id: "chat.message.image.retry" }, { timeout: 30_000, stable: 500 });
  const retried = await json(["ox", "--host", qa.debugEndpoint, "host", "logs", "--grep", "ImageWidgetView.load failed", "--json"]);
  assert(retried.length > failures.length, "Retry must issue another image load");
  await screenshot("failure-retry");
  checks.push("remote failure displays a retry control");
  await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, chat: qa.values.chat, checks }, null, 2) + "\n");
} finally {
  release();
}
console.log(`PASS image embed E2E (${checks.length} checks); evidence: ${directory}`);
