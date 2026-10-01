import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostRPCClient } from "../apps/cli/src/host-rpc.ts";
import { qaCommand } from "./qa-config.ts";

// Opt-in live E2E. Claim a free simulator first; Doubao must already be signed out.
// Never clears website data, changes credentials, or signs out an existing account.
const { device, debugEndpoint } = qaCommand({
  usage: "bun tooling/model-provider-auth-qa.ts --device ox-N\nRequires a running Debug Host on the matching port and signed-out Doubao.",
});
const output = mkdtempSync(join(tmpdir(), "openox-model-auth-"));
const host = new HostRPCClient(debugEndpoint);

function command(args: string[], allowFailure = false) {
  const result = Bun.spawnSync(args, { stdout: "pipe", stderr: "pipe" });
  const text = result.stdout.toString();
  if (result.exitCode !== 0 && !allowFailure) throw new Error(`${args[0]} failed: ${result.stderr.toString()}`);
  return { code: result.exitCode, text };
}
function ox(...args: string[]) { return command(["ox", "--host", debugEndpoint, ...args]); }
function sim(...args: string[]) { return command(["sim", "--device", device, ...args]); }
function check(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
type Element = { AXUniqueId?: string; AXLabel?: string; AXValue?: string; enabled?: boolean; children?: Element[] };
function elements(): Element[] {
  const tree = JSON.parse(sim("describe").text) as { accessibility: Element[] };
  const flatten = (rows: Element[]): Element[] => rows.flatMap(row => [row, ...flatten(row.children ?? [])]);
  return flatten(tree.accessibility);
}
function element(id: string) { return elements().find(row => row.AXUniqueId === id); }
function tap(id: string) { sim("tap", "--id", id, "--wait", "5000", "--stable", "300"); }
function wait(id: string) { sim("wait", "--id", id, "--timeout", "30000", "--stable", "300"); }
function screenshot(name: string) { sim("screenshot", "--out", join(output, `${name}.png`)); }
function inspect() { return JSON.parse(ox("chat", "inspect", "--json").text) as { id: string; model: { id: string }; messages: unknown[] }; }
async function requireSignedOut() {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const services = JSON.parse(ox("host", "services", "--json").text) as { domain: string; signIn: string }[];
    const state = services.find(row => row.domain === "doubao.com")?.signIn;
    if (state === "signedOut") return;
    check(state === "unknown" || state === "checking:unknown" || state === "checking:signedOut", "Doubao must be signed out; do not sign out a real account to run this test.");
    await Bun.sleep(200);
  }
  throw new Error("Doubao sign-in probe did not settle.");
}

try {
  // Opening the picker runs a fresh probe, including on a newly launched Host.
  ox("chat", "new", "--temporary", "--provider", "mock", "--model", "mock");
  tap("chat.modelPicker");
  tap("chat.modelProvider");
  tap("chat.modelProviderOption.web:doubao.com");
  wait("chat.modelKeySignIn.web:doubao.com");
  await requireSignedOut();
  check(!element("chat.modelSelection"), "Signed-out website models must not be displayed.");
  check(inspect().model.id === "mock", "Signed-out selection must preserve the current model.");
  screenshot("signed-out-picker");
  tap("chat.modelClose");

  // Simulate a saved chat whose website session has expired, bypassing the picker.
  ox("chat", "new", "--temporary", "--provider", "web:doubao.com", "--model", "website-default");
  wait("chat.modelAccessNotice");
  await requireSignedOut();
  screenshot("early-sign-in-warning");
  const before = inspect();
  const draft = "Keep this draft until I sign in.";
  await host.call("debug.composer.setDraft", 5000, { prompt: draft });
  tap("chat.send");
  wait("chat.modelKeySignIn.web:doubao.com");
  check(inspect().messages.length === before.messages.length, "Blocked UI send must not enqueue a message.");
  tap("chat.modelClose");
  check((await host.call("debug.composer.formatting", 5000)).text === draft, "Blocked send must preserve the draft.");

  // Non-UI clients also get a provider-level preflight and actionable error.
  await requireSignedOut();
  const outcome = command(["ox", "--host", debugEndpoint, "chat", "send", "Reply hello.", "--json", "--timeout", "60000"], true);
  check(outcome.code === 1, "Signed-out generation must fail.");
  const result = JSON.parse(outcome.text) as { error?: string };
  check(result.error?.includes("Sign in with Doubao Web") && !result.error.includes("startModelGeneration"), "Generation failure must be user-facing, not an internal Action error.");
  const logs = JSON.parse(ox("host", "logs", "--grep", "ModelService.", "--tail", "100", "--json").text) as { message: string }[];
  check(logs.some(row => row.message.includes("ModelService.auth domain=doubao.com state=signedOut")), "Provider preflight must log the denied authentication state.");
  check(!logs.some(row => row.message.includes("ModelService.start domain=doubao.com")), "Signed-out preflight must not submit a generation.");

  // Recover through the warning, without discarding the blocked draft.
  tap("chat.modelAccessNotice");
  tap("chat.modelProvider");
  tap("chat.modelProviderOption.mock");
  tap("chat.modelClose");
  check(!element("chat.modelAccessNotice"), "Switching models must remove the website sign-in warning.");
  check((await host.call("debug.composer.formatting", 5000)).text === draft, "Changing the model must preserve the blocked draft.");
  ox("chat", "send", "Reply hello.", "--json", "--timeout", "30000");
  console.log(`PASS website model authentication E2E (${device}); screenshots: ${output}`);
} finally {
  host.close();
}
