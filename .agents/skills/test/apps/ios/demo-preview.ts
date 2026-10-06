import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const config = qaCommand({ usage: "Usage: bun run test:demo --device ox-N\nExercises native demo scenes without player controls or live model/service calls." });
const bundle = "ai.oxcraft.bot";
const directory = await mkdtemp(join(tmpdir(), "ox-demo-preview-"));
const release = claimSimulator(config.device);
const checks: string[] = [];
const launch = ["run", bundle, "--project", "apps/ios/Ox.xcodeproj", "--scheme", "ios", "--env", `OX_DEBUG_ENDPOINT=${config.debugEndpoint}`];
const sim = async (...args: string[]) => JSON.parse((await run(["sim", "--device", config.device, ...args], { capture: true })).stdout);
type Element = { AXUniqueId?: string; AXLabel?: string; AXValue?: string; frame?: { width: number; height: number }; children?: Element[] };
const elements = async (): Promise<Element[]> => {
  const tree = await sim("describe") as { accessibility: Element[] };
  const flatten = (nodes: Element[]): Element[] => nodes.flatMap(node => [node, ...flatten(node.children ?? [])]);
  return flatten(tree.accessibility);
};
const check = (condition: unknown, label: string) => {
  if (!condition) throw new Error(label);
  checks.push(label);
};
const wait = (id: string) => sim("wait", "--id", id, "--timeout", "10000", "--stable", "300");
const value = async (id: string) => (await elements()).find(element => element.AXUniqueId === id)?.AXValue ?? "";
async function snapshot(label: string) {
  const output: Record<string, string | null> = {};
  for (const [name, path] of [["documents", "Documents"], ["local", "Library/Application Support/service-repositories/local"]] as const) {
    const dest = join(directory, label, name);
    const pull = await run(["sim", "--device", config.device, "file", "pull", bundle, path, "--dest", dest], { capture: true, allowFailure: true });
    if (pull.code !== 0) { output[name] = null; continue; }
    const hash = createHash("sha256");
    const visit = async (root: string) => {
      for (const entry of (await readdir(root, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
        hash.update(entry.name);
        if (entry.isDirectory()) await visit(join(root, entry.name));
        else if (entry.isFile()) hash.update(await readFile(join(root, entry.name)));
      }
    };
    await visit(dest);
    output[name] = hash.digest("hex");
  }
  return output;
}
let launched = false;
async function scene(name: string, completed = true, autoplay = false) {
  await sim(...launch, "--env", "OX_DEMO=1", "--env", `OX_DEMO_SCENE=${name}`,
    "--env", `OX_DEMO_COMPLETE=${completed ? 1 : 0}`, "--env", `OX_DEMO_AUTOPLAY=${autoplay ? 1 : 0}`);
  launched = true;
  const heading = ["connect", "local", "yours"].includes(name);
  await wait(heading ? "demo.chapter" : name === "providers" ? "demo.provider.chatgpt"
    : completed && !["research", "jobs"].includes(name) ? "chat.message.user" : "chat.input");
  const tree = await elements();
  check(!tree.some(element => ["demo.playPause", "demo.record", "demo.disclosure", "demo.airplane"].includes(element.AXUniqueId ?? "")), `${name}: no custom player or simulated system UI`);
  await sim("screenshot", "--out", join(directory, `${name}${autoplay ? "-autoplay" : ""}.png`));
  return tree;
}
try {
  if (!await requireSimulator(config.device)) await sim("devices", "boot", config.device);
  const before = await snapshot("before");
  check(before.documents !== null, "installed profile snapshot available");
  const defaultsBefore = await run(["sim", "--device", config.device, "defaults", "read", bundle, "chat.importMemoryIntentDisplays"], { capture: true, allowFailure: true });
  let tree = await scene("connect");
  check(tree.some(element => element.AXLabel === "Connect anything, Ox works across AI assistants, apps, and websites to get things done for you."), "verbatim copy in native onboarding row");
  tree = await scene("memory");
  check(tree.some(element => element.AXLabel === "Import all of my memory into Ox."), "exact memory prompt in native user bubble");
  check(tree.some(element => element.AXUniqueId === "demo.thinking"), "native completed task trace");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("private memory stores")), "source-specific memory reply includes access limits");
  for (const id of ["chat.message.copy", "chat.message.share"]) {
    check(tree.some(element => element.AXUniqueId === id), `native completed response control: ${id}`);
  }
  for (const domain of ["chatgpt.com", "claude.ai", "muse.ai"]) {
    check(tree.some(element => element.AXUniqueId === `conversation.servicePill.${domain}` && element.AXValue === "Signed in"), `native memory service chip with fixture auth status: ${domain}`);
  }
  check(!tree.some(element => element.AXLabel?.startsWith("Remove ")), "memory uses native status chips, not removable attachment chips");
  await sim("tap", "--id", "demo.thinking");
  await sim("wait", "--label", "Steps", "--timeout", "10000", "--stable", "300");
  const steps = await elements();
  for (const text of ["Reading preferences exposed by ChatGPT, Claude, and Muse", "Merging overlaps and preserving source labels", "Saving the combined notes to Ox memory"]) {
    check(steps.some(element => element.AXValue === text), `native trace detail: ${text}`);
  }
  await sim("screenshot", "--out", join(directory, "memory-steps.png"));
  for (const [name, prompt, domains] of [
    ["research", "Do deep research on stock trading tips across my assistants.", ["manus.im", "doubao.com", "grok.com"]],
    ["jobs", "What are the best job opportunities for me?", ["outlook.live.com", "linkedin.com", "www.1point3acres.com"]],
  ] as const) {
    tree = await scene(name);
    check(await value("chat.input") === prompt, `exact ${name} prompt in native composer`);
    const send = tree.find(element => element.AXUniqueId === "chat.send")?.frame;
    check(send?.width === 44 && send.height === 44, `${name} Send matches the production 44-point tap target at standard text size`);
    check(!tree.some(element => element.AXUniqueId === "demo.reply"), `${name} remains typing-only`);
    check(domains.every(domain => tree.some(element => element.AXUniqueId === `conversation.servicePill.${domain}` && element.AXValue === "Signed in")), `${name} has assigned three services with fixture auth status`);
  }
  tree = await scene("offline");
  check(tree.some(element => element.AXLabel === "Help me plan a focused morning."), "stored conversation uses native messages, no fabricated radio control");
  tree = await scene("providers");
  check(tree.some(element => element.AXUniqueId === "demo.provider.chatgpt"), "native provider picker");
  tree = await scene("reddit");
  check(tree.some(element => element.AXUniqueId === "conversation.servicePill.reddit.com"), "reusable Reddit appears in native composer");
  await scene("reuse");
  await scene("memory", false, true);
  await wait("demo.thinking");
  tree = await elements();
  check(!tree.some(element => element.AXUniqueId === "chat.message.copy"), "response controls stay hidden during work");
  await sim("wait", "--id", "demo.reply", "--timeout", "20000", "--stable", "300");
  await sim("wait", "--id", "chat.stop", "--missing", "--timeout", "30000", "--stable", "300");
  tree = await elements();
  check(tree.some(element => element.AXLabel === "Import all of my memory into Ox."), "timeline types, sends, and streams through native components");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("Source labels are kept so you can review the merge.")), "word-burst stream preserves the complete reply");
  await scene("connect"); // Cancel playback before measuring persisted state.
  const after = await snapshot("after");
  check(JSON.stringify(before) === JSON.stringify(after), "profile and Local repository contents unchanged");
  const defaultsAfter = await run(["sim", "--device", config.device, "defaults", "read", bundle, "chat.importMemoryIntentDisplays"], { capture: true, allowFailure: true });
  check(defaultsBefore.code === defaultsAfter.code && defaultsBefore.stdout === defaultsAfter.stdout, "composer suggestion preference unchanged");
  console.log(JSON.stringify({ passed: true, checks, diagnostics: directory }, null, 2));
} catch (error) {
  console.error(`Diagnostics: ${directory}`);
  throw error;
} finally {
  try { if (launched) await sim(...launch); }
  finally { release(); }
}
