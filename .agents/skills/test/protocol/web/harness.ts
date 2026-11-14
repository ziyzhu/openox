import { run } from "../../../../lib.ts";
import { elements, iosTarget } from "../../../setup/scripts/ios.ts";
import type { Fixtures } from "./server.ts";
import type { Account, Site } from "./sites/shared.ts";

type Snapshot = {
  isBusy: boolean;
  pendingPrompt: { id: string; prompt: string; options: string[] } | null;
  messages: Array<{ type: string; toolResult?: { toolCallId: string; isError: boolean; content: Array<{ text?: { text: string } }> } }>;
};

export type Harness = ReturnType<typeof harness>;
export type Prompt = { id: string; prompt: string; options: string[] };
export type Responder = (prompt: Prompt) => string | undefined;

export const wait = "";
export const approveSecretUse: Responder = prompt => /to use the saved secret/.test(prompt.prompt) ? "Approve" : undefined;

export function harness(options: { device: string; debugEndpoint: string; fixtures: Fixtures; sites: Site[]; evidence: string }) {
  const ios = iosTarget(options.device);
  let conversation = "";
  let prompts: string[] = [];
  const saved = new Set<string>();

  async function ox(args: string[], flags: { conversation?: boolean; allowFailure?: boolean } = {}) {
    const result = await run(["bun", "apps/cli/src/ox.ts", "--host", options.debugEndpoint,
      ...flags.conversation ? ["--conversation", conversation] : [], ...args, "--json"], { capture: true, allowFailure: flags.allowFailure });
    if (result.code) return { error: (result.stderr || result.stdout).trim() };
    return JSON.parse(result.stdout);
  }

  async function snapshot(): Promise<Snapshot> {
    return ox(["conversation", "inspect"], { conversation: true });
  }

  async function idle(answer: Responder = approveSecretUse, timeout = 60_000): Promise<Snapshot> {
    const deadline = Date.now() + timeout;
    const answered = new Set<string>();
    for (;;) {
      const current = await snapshot();
      if (!current.isBusy && !current.pendingPrompt) return current;
      const prompt = current.pendingPrompt;
      if (Date.now() > deadline) throw new Error(`Turn did not finish; pending=${prompt?.prompt ?? "none"}`);
      if (prompt && !answered.has(prompt.id)) {
        const reply = answer(prompt);
        if (reply === undefined) throw new Error(`Unexpected prompt: ${prompt.prompt.split("\n")[0]}`);
        if (reply === wait) { await Bun.sleep(250); continue; }
        prompts.push(prompt.prompt.split("\n")[0]!);
        answered.add(prompt.id);
        await ox(["conversation", "respond", reply, "--prompt", prompt.id], { conversation: true });
      }
      await Bun.sleep(250);
    }
  }

  async function pending(timeout = 20_000) {
    const deadline = Date.now() + timeout;
    for (;;) {
      const current = await snapshot();
      if (current.pendingPrompt) return current.pendingPrompt;
      if (!current.isBusy) throw new Error("Turn finished without the expected prompt");
      if (Date.now() > deadline) throw new Error("Expected prompt did not appear");
      await Bun.sleep(250);
    }
  }

  function lastResult(current: Snapshot): unknown {
    const result = current.messages.filter(message => message.type === "toolResult").at(-1)?.toolResult;
    const text = result?.content.map(part => part.text?.text ?? "").join("") ?? "";
    if (!result || result.isError) throw new Error(`Turn script failed: ${text.slice(0, 2000)}`);
    const line = text.split("\n").find(entry => entry.startsWith("RESULT "));
    if (!line) throw new Error(`Turn script printed no RESULT line: ${text.slice(0, 2000)}`);
    return JSON.parse(line.slice("RESULT ".length));
  }

  async function begin(script: string) {
    const body = `const result = await (async () => {\n${script}\n})();\nconsole.log("RESULT " + JSON.stringify(result ?? null));`;
    const sent = await ox(["conversation", "send", `execute\n${body}`], { conversation: true, allowFailure: true });
    if (sent.error && !/needs attention/.test(sent.error)) throw new Error(sent.error);
  }

  async function turn(script: string, answer?: Responder): Promise<any> {
    await begin(script);
    return lastResult(await idle(answer));
  }

  async function waitMatching(pattern: RegExp, timeout = 20_000): Promise<string> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const tree = elements(await ios.describe());
      const bottom = tree.find(element => element.AXUniqueId?.startsWith("conversation.servicePill."))?.frame?.y
        ?? tree.find(element => element.AXUniqueId === "conversation.input")?.frame?.y ?? 700;
      const matches = tree.filter(element => pattern.test(element.AXUniqueId ?? "") && (element.frame?.width ?? 0) > 0);
      const visible = matches.filter(element => element.frame!.y >= 110 && element.frame!.y + element.frame!.height <= bottom).at(-1);
      if (visible) return visible.AXUniqueId!;
      const target = matches.at(-1)?.frame;
      if (target) {
        const [from, to] = target.y < 100 ? [260, 460] : [600, 400];
        await run(["idb", "ui", "swipe", "396", String(from), "396", String(to), "--duration", "0.4", "--udid", await ios.udid()], { capture: true });
      }
      await Bun.sleep(400);
    }
    throw new Error(`Timed out waiting for a control matching ${pattern}`);
  }

  async function tapMatching(pattern: RegExp, timeout = 20_000) {
    await ios.tap({ id: await waitMatching(pattern, timeout) }, { stable: 300 });
  }

  async function webField(label: string, timeout = 20_000) {
    const udid = await ios.udid();
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      for (let y = 100; y < 700; y += 16) {
        const hit = await run(["idb", "ui", "describe-point", "200", String(y), "--udid", udid], { capture: true, allowFailure: true });
        const match = hit.code ? undefined : elements(JSON.parse(hit.stdout || "null")).find(element => element.AXLabel === label && /TextField/.test(String(element.type ?? "")));
        if (match?.frame) return { x: Math.round(match.frame.x + match.frame.width / 2), y: Math.round(match.frame.y + match.frame.height / 2) };
      }
      await Bun.sleep(250);
    }
    throw new Error(`Timed out waiting for web field "${label}"`);
  }

  async function fillWeb(label: string, value: string) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const point = await webField(label);
      await run(["idb", "ui", "tap", String(point.x), String(point.y), "--udid", await ios.udid()], { capture: true });
      await Bun.sleep(800);
    }
    await ios.text(value);
  }

  async function fill(id: string, value: string) {
    await ios.tap({ id }, { stable: 300 });
    await Bun.sleep(500);
    await ios.text(value);
  }

  return {
    ios, ox, turn, begin, idle, pending, lastResult, waitMatching, tapMatching, fillWeb,
    async pressReturn() { await run(["idb", "ui", "key", "40", "--udid", await ios.udid()], { capture: true }); },
    get fixtures() { return options.fixtures; },
    get evidence() { return options.evidence; },
    get prompts() { return prompts; },
    site: (name: string) => options.sites.find(site => site.name === name)!,
    async newConversation() {
      const created = await ox(["conversation", "new", "--provider", "mock", "--model", "mock"]);
      if (!created.conversationId) throw new Error(`Conversation was not created: ${JSON.stringify(created)}`);
      conversation = created.conversationId;
      prompts = [];
    },
    async forgetLogins() {
      for (const key of saved) {
        await turn(`return await ox.secret.delete({ purpose: "Remove fixture login", key: ${JSON.stringify(key)} });`,
          prompt => prompt.options.includes("Delete") ? "Delete" : prompt.prompt.startsWith("Delete a secret") ? "Approve" : undefined);
        saved.delete(key);
      }
    },
    async invoke(target: string, input: unknown = {}, extra: string[] = []) {
      return ox(["service", "invoke", target, "--args", JSON.stringify(input), ...extra], { allowFailure: true });
    },
    async saveLogin(key: string, serviceID: string, account: Account) {
      saved.add(key);
      await begin(`return await ox.secret.add({ purpose: "Save fixture login", key: ${JSON.stringify(key)}, type: "account", serviceID: ${JSON.stringify(serviceID)} });`);
      await pending();
      await fill("secret-entry-field-username", account.username);
      await fill("secret-entry-field-password", account.password);
      await ios.tap({ id: "secret-entry-save" }, { stable: 300 });
      const result = lastResult(await idle(prompt => prompt.prompt.startsWith("Save a secret") ? wait : undefined)) as { status: string };
      if (result.status !== "saved") throw new Error(`Saved login ${key} was ${result.status}`);
    },
    async screenshot(name: string) {
      await ios.screenshot(`${options.evidence}/${name}.png`);
    },
  };
}
