import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const config = qaCommand({
  usage: "Usage: bun run test:demo --device ox-N [--app /absolute/Ox.app]\nExercises native demo scenes without player controls or live model/service calls.",
  options: { app: { type: "string" } },
});
const bundle = "ai.oxcraft.bot";
const directory = await mkdtemp(join(tmpdir(), "ox-demo-preview-"));
const release = claimSimulator(config.device);
const checks: string[] = [];
const launch = ["run", bundle,
  ...(config.values.app ? ["--app", config.values.app] : ["--project", "apps/ios/Ox.xcodeproj", "--scheme", "ios"]),
  "--env", `OX_DEBUG_ENDPOINT=${config.debugEndpoint}`];
const sim = async (...args: string[]) => JSON.parse((await run(["sim", "--device", config.device, ...args], { capture: true })).stdout);
type Element = { AXUniqueId?: string; AXLabel?: string; AXValue?: string; frame?: { x: number; width: number; height: number }; children?: Element[] };
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
async function scene(name: string, completed = true, autoplay = false, time = 0) {
  await sim(...launch, "--env", "OX_DEMO=1", "--env", `OX_DEMO_SCENE=${name}`,
    "--env", `OX_DEMO_COMPLETE=${completed ? 1 : 0}`, "--env", `OX_DEMO_AUTOPLAY=${autoplay ? 1 : 0}`,
    "--env", `OX_DEMO_TIME=${time}`);
  launched = true;
  const heading = ["connect", "local", "yours"].includes(name);
  await wait(heading ? "demo.chapter" : name === "providers" ? "demo.provider.chatgpt"
    : completed && !["planning", "publishing", "creative"].includes(name) ? "chat.message.user" : "chat.input");
  const tree = await elements();
  check(!tree.some(element => ["demo.playPause", "demo.record", "demo.disclosure", "demo.airplane"].includes(element.AXUniqueId ?? "")), `${name}: no custom player or simulated system UI`);
  await sim("screenshot", "--out", join(directory, `${name}${autoplay ? "-autoplay" : name === "creative" ? `-${time}` : ""}.png`));
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
  check(tree.some(element => element.AXLabel === "Import my memory from ChatGPT, Claude, and Muse into Ox, and merge duplicates."), "exact memory prompt in native user bubble");
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
    ["planning", "Email Alex that the release is ready, schedule a review tomorrow at 10, and add a prep reminder at 9.", ["mail.google.com", "ios:calendar", "ios:reminders"]],
    ["publishing", "Open a pull request for feature/checklist in my demo repo, email Alex the link, and add a review reminder.", ["github.com", "mail.google.com", "ios:reminders"]],
  ] as const) {
    tree = await scene(name);
    check(await value("chat.input") === prompt, `exact ${name} prompt in native composer`);
    const send = tree.find(element => element.AXUniqueId === "chat.send")?.frame;
    check(send?.width === 44 && send.height === 44, `${name} Send matches the production 44-point tap target at standard text size`);
    check(!tree.some(element => element.AXUniqueId === "demo.reply"), `${name} remains typing-only`);
    check(domains.every(domain => tree.some(element => element.AXUniqueId === `conversation.servicePill.${domain}` && element.AXValue === (domain.startsWith("ios:") ? "Permission granted" : "Signed in"))), `${name} has assigned write services with snapshot access status`);
  }
  tree = await scene("offline");
  check(tree.some(element => element.AXLabel === "Add a reminder for tomorrow at 9 to start a 45-minute focus block."), "stored conversation delegates an on-device write, no fabricated radio control");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("Added **Morning focus block** to Reminders")), "stored reply reports a created reminder fixture");
  check(tree.some(element => element.AXUniqueId === "conversation.servicePill.ios:reminders" && element.AXValue === "Permission granted"), "on-device reminder chip uses snapshot permission status");
  tree = await scene("providers");
  check(tree.some(element => element.AXUniqueId === "demo.provider.chatgpt"), "native provider picker");
  tree = await scene("reddit");
  check(tree.some(element => element.AXUniqueId === "conversation.servicePill.reddit.com"), "reusable Reddit appears in native composer");
  check(tree.some(element => element.AXLabel === "Create a reusable Reddit service that can publish posts and reply to comments."), "Reddit prompt creates reusable write actions");
  check(tree.some(element => element.AXUniqueId === "conversation.servicePill.reddit.com" && element.AXValue === "Signed in"), "Reddit write actions use snapshot sign-in status");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("require your approval")), "Reddit write fixture describes approval requirements");
  tree = await scene("reuse");
  check(tree.some(element => element.AXLabel === "Post my morning routine to my Reddit profile using the new service."), "reuse prompt publishes rather than retrieves advice");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("Published **My focused-morning routine**")), "reuse reply reports a published post fixture");
  await scene("memory", false, true);
  await wait("demo.thinking");
  tree = await elements();
  check(!tree.some(element => element.AXUniqueId === "chat.message.copy"), "response controls stay hidden during work");
  await sim("wait", "--id", "demo.reply", "--timeout", "20000", "--stable", "300");
  await sim("wait", "--id", "chat.stop", "--missing", "--timeout", "30000", "--stable", "300");
  tree = await elements();
  check(tree.some(element => element.AXLabel === "Import my memory from ChatGPT, Claude, and Muse into Ox, and merge duplicates."), "timeline types, sends, and streams through native components");
  check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes("Source labels are kept so you can review the merge.")), "word-burst stream preserves the complete reply");
  const screenshotDirectory = join(directory, "app-store");
  await mkdir(screenshotDirectory);
  let screenshotSize: string | undefined;
  for (const [index, [name, outcome]] of ([
    ["planning", "The email includes the review time."],
    ["publishing", "The branch has not been merged."],
    ["memory", "Source labels are kept so you can review the merge."],
    ["reminder", "Added **Morning focus block** to Reminders"],
    ["service", "Both write actions require your approval"],
    ["post", "Published **My focused-morning routine**"],
  ] as const).entries()) {
    await sim(...launch, "--env", `OX_APP_STORE_SCREENSHOT=${name}`);
    await wait("demo.reply");
    tree = await elements();
    check(tree.some(element => element.AXUniqueId === "chat.message.user"), `App Store ${name}: native user message`);
    check(tree.some(element => element.AXUniqueId === "demo.reply" && element.AXLabel?.includes(outcome)), `App Store ${name}: completed action fixture`);
    check(tree.some(element => element.AXUniqueId === "chat.message.copy"), `App Store ${name}: native completed response controls`);
    check(!tree.some(element => ["demo.chapter", "demo.playPause", "demo.record", "demo.disclosure", "demo.airplane", "chat.stop", "chat.send"].includes(element.AXUniqueId ?? "")), `App Store ${name}: static app-only scene without overlays or playback`);
    check(await value("chat.input") === "Type a message", `App Store ${name}: empty native composer placeholder`);
    const path = join(screenshotDirectory, `${String(index + 1).padStart(2, "0")}-${name}.png`);
    await sim("screenshot", "--out", path);
    const png = await readFile(path);
    const width = png.readUInt32BE(16);
    const height = png.readUInt32BE(20);
    check(height > width && (!screenshotSize || screenshotSize === `${width}x${height}`), `App Store ${name}: consistent native portrait resolution`);
    screenshotSize = `${width}x${height}`;
  }
  check((await readdir(screenshotDirectory)).length === 6, "exactly six app-only screenshot PNGs");
  let creativeHeight: number | undefined;
  let openingChipX: number | undefined;
  const creativePositions = new Map<number, number>();
  let fullScrollTravel = 0;
  for (const time of [0, 3, 4, 5, 10, 15, 20]) {
    tree = await scene("creative", false, false, time);
    check(await value("chat.input") === "Type a message", `creative ${time}s: composer remains empty`);
    const speech = tree.find(element => element.AXUniqueId === "chat.speechHold")?.frame;
    check(speech?.width === 44 && speech.height === 44, `creative ${time}s: normal production 44-point control size`);
    const input = tree.find(element => element.AXUniqueId === "chat.input")?.frame;
    check(input && (creativeHeight === undefined || input.height === creativeHeight), `creative ${time}s: stable empty composer height`);
    creativeHeight = input?.height;
    const chips = tree.filter(element => element.AXUniqueId?.startsWith("conversation.servicePill."));
    check(chips.length === 13 && chips.every(element => element.AXValue === "Signed in"), `creative ${time}s: all 13 assistants have snapshot sign-in status`);
    check(chips.every(element => element.frame?.height === 44), `creative ${time}s: normal production 44-point chip size`);
    check(!tree.some(element => ["chat.message.user", "demo.reply", "demo.thinking", "chat.openSidebar", "chat.modelPicker"].includes(element.AXUniqueId ?? "")), `creative ${time}s: only production chips and composer`);
    const x = chips[0]?.frame?.x;
    if (x !== undefined) creativePositions.set(time, x);
    if (time === 0) {
      openingChipX = x;
      const last = chips.at(-1)?.frame;
      const viewport = tree[0]?.frame;
      check(last && viewport && x !== undefined, "creative: scroll content geometry available");
      fullScrollTravel = last!.x + last!.width - x! - (viewport!.width - 2 * x!);
    }
    if (time === 10) check(x !== undefined && openingChipX !== undefined && x < openingChipX - 300, "creative: limited-distance scroll reveals more assistants");
    if (time === 20) check(x === openingChipX, "creative: opening scroll position restored at loop boundary");
  }
  const travel = Math.abs(creativePositions.get(10)! - creativePositions.get(0)!);
  check(Math.abs(travel - fullScrollTravel / 2) < 1, "creative: half-distance native scroll keeps the loop at 20 seconds");
  const step = Math.abs(creativePositions.get(5)! - creativePositions.get(4)!);
  const previousStep = Math.abs(creativePositions.get(4)! - creativePositions.get(3)!);
  check(Math.abs(step - previousStep) < 1, "creative: steady mid-scroll speed instead of accelerating through the center");
  check(step < travel * 0.13, "creative: peak speed stays below 13 percent of total travel per second");
  await scene("connect");
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
