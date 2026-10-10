import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/image-widget.ts --device ox-N --chat <saved-Mock-QA-chat-seeded-with-0> --app /absolute/Ox.app [--bundle id] [--output /tmp/directory]\nUses the assigned loopback Host. Retains run-owned QA artifacts and chat for visual review; never changes approval policies or credentials.",
  options: { chat: { type: "string" }, app: { type: "string" }, bundle: { type: "string" }, output: { type: "string" } },
});
if (!qa.values.chat || !qa.values.app) throw new Error("Pass a seeded saved QA chat and the freshly built app");
const localConfig = await readFile(join(ROOT, "apps/ios/Local.xcconfig"), "utf8").catch(() => "");
const bundle = qa.values.bundle ?? Bun.env.OX_BUNDLE_ID
  ?? /^OX_BUNDLE_IDENTIFIER\s*=\s*([^\s/]+)/m.exec(localConfig)?.[1] ?? "ai.openox.local";
const directory = resolve(qa.values.output ?? `/tmp/ox-image-widget-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"));
const target = ["ox", "--host", qa.debugEndpoint, "--chat", qa.values.chat];
const imageURL = "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?w=960&h=640&fit=crop";
const prefix = `qa-image-${crypto.randomUUID().slice(0, 8)}`;
const checks: string[] = [];
async function json(args: string[]) {
  return JSON.parse((await run(args, { capture: true })).stdout);
}
async function call(name: string, args: Record<string, unknown>) {
  return (await json([...target, "vm", "call", name, "--args", JSON.stringify({ purpose: "Verify image widget", ...args }), "--json"])).value;
}
async function inspect() {
  return json([...target, "chat", "inspect", "--json"]);
}
async function present(image: string) {
  await json([...target, "chat", "send", `execute\nawait ox.widget.image({ purpose: "Verify image widget", image: ${JSON.stringify(image)} });`, "--json"]);
}
function images(state: Awaited<ReturnType<typeof inspect>>) {
  return state.blocks.flatMap((block: { kind: { items?: { image?: { source: { type: string; artifact?: string; url?: string } } }[] } }) =>
    block.kind.items?.flatMap(item => item.image ? [item.image.source] : []) ?? []);
}
async function sim(...args: string[]) {
  return run(["sim", "--device", qa.device, ...args], { capture: true });
}
async function bottom() {
  const tree = await json(["sim", "--device", qa.device, "describe"]);
  if (JSON.stringify(tree).includes('"chat.scrollToBottom"')) {
    await sim("tap", "--id", "chat.scrollToBottom");
    await sim("wait", "--id", "chat.scrollToBottom", "--missing", "--timeout", "5000");
  }
}
async function screenshot(name: string) {
  await sim("screenshot", "--out", join(directory, `${name}.png`));
  await writeFile(join(directory, `${name}-ax.json`), (await sim("describe")).stdout);
}
await requireSimulator(qa.device);
const release = claimSimulator(qa.device);
try {
  await mkdir(directory, { recursive: true });
  await json([...target, "chat", "open", "--json"]);
  const initial = await inspect();
  assert.equal(initial.isBusy, false);
  assert.equal(initial.model.id, "mock");
  assert.equal(initial.messages[0]?.user?.content[0]?.text?.text, "0");
  assert.equal(initial.messages.filter((message: { type: string }) => message.type === "user").length, 1);
  assert.equal(images(initial).length, 0);
  const schema = await json([...target, "vm", "functions", "--json"]);
  assert.deepEqual(new Set(schema["ox.widget.image"].inputSchema.required), new Set(["image", "purpose"]));
  await present(imageURL);
  await sim("wait", "--id", "chat.message.image.open", "--timeout", "30000", "--stable", "300");
  await screenshot("remote-inline");
  await sim("tap", "--id", "chat.message.image.open");
  await sim("wait", "--id", "chat.message.image.close", "--timeout", "5000", "--stable", "300");
  await screenshot("remote-zoom");
  await sim("tap", "--id", "chat.message.image.close");
  checks.push("remote HTTPS image renders inline and opens the zoomable viewer");
  for (const image of ["http://example.com/a.png", "https://user:password@example.com/a.png", "data:image/png;base64,AA==", `${prefix}-missing.png`]) {
    await assert.rejects(() => call("ox.widget.image", { image }), /HTTPS URL|does not exist|missing|not found/i);
  }
  const text = await call("ox.fs.write", { path: `artifacts/${prefix}.txt`, content: "Not an image" });
  assert(text);
  await assert.rejects(() => call("ox.widget.image", { image: `${prefix}.txt` }), /not an image/);
  checks.push("HTTP, embedded credentials, data URLs, missing files and non-image artifacts are rejected");
  const artifact = await call("ox.artifact.import", { url: imageURL, filename: `${prefix}.jpg` });
  assert.equal(artifact.kind, "image");
  await present(artifact.filename);
  const renamed = await call("ox.artifact.rename", { filename: artifact.filename, newFilename: `${prefix}-renamed.jpg` });
  const before = await inspect();
  assert.deepEqual(images(before), [{ type: "remote", url: imageURL }, { type: "artifact", artifact: renamed.filename }]);
  assert(!before.messages.some((message: unknown) => JSON.stringify(message).includes('"type":"attachment"')));
  await bottom();
  await screenshot("local-inline");
  checks.push("local artifact image references follow rename without attaching pixels to model context");
  await sim("run", bundle, "--app", resolve(qa.values.app), "--env", "OX_HOST_LOOPBACK=1", "--env", `OX_DEBUG_ENDPOINT=${qa.debugEndpoint}`);
  let ready = false;
  for (let attempt = 0; attempt < 40 && !ready; attempt++) {
    try { await json(["ox", "--host", qa.debugEndpoint, "host", "describe", "--json"]); ready = true; }
    catch { await Bun.sleep(250); }
  }
  assert(ready, "Host must become ready after relaunch");
  await json([...target, "chat", "open", "--json"]);
  assert.deepEqual(images(await inspect()), images(before));
  await bottom();
  await screenshot("reopened");
  checks.push("remote and renamed local image widgets survive process relaunch");
  await present("https://openox.ai/qa-image-widget-missing.png");
  await bottom();
  await sim("wait", "--id", "chat.message.image.retry", "--timeout", "30000", "--stable", "300");
  const failures = await json(["ox", "--host", qa.debugEndpoint, "host", "logs", "--grep", "ImageWidgetView.load failed", "--json"]);
  await sim("tap", "--id", "chat.message.image.retry");
  await sim("wait", "--id", "chat.message.image.retry", "--timeout", "30000", "--stable", "500");
  const retried = await json(["ox", "--host", qa.debugEndpoint, "host", "logs", "--grep", "ImageWidgetView.load failed", "--json"]);
  assert(retried.length > failures.length, "Retry must issue another image load");
  await screenshot("failure-retry");
  checks.push("remote failure displays a retry control");
  await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, chat: qa.values.chat, checks, retainedArtifacts: [text.path, renamed.filename] }, null, 2) + "\n");
} finally {
  release();
}
console.log(`PASS image widget E2E (${checks.length} checks); evidence: ${directory}`);
