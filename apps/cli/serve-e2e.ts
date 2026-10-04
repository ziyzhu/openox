/** Real MCP + real Pi subprocess lifecycle check. No model calls unless --prompt is supplied. */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createHttpHandler } from "./src/serve/server.ts";
import { Sessions } from "./src/serve/sessions.ts";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const directory = await realpath(await mkdtemp(join(tmpdir(), "ox-serve-e2e-")));
let endpoint!: URL;
let sessions: Sessions | undefined;
let stopServer: (() => void) | undefined;
let client: Client | undefined;
function check(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function start(): Promise<void> {
  // Internal network harness exercises the production handler without publishing a tailnet route.
  sessions = new Sessions(join(directory, "data", "sessions"), directory, "pi");
  await sessions.load();
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: createHttpHandler(sessions, new Set(["127.0.0.1"])) });
  stopServer = () => { server.stop(true); };
  endpoint = new URL(`http://127.0.0.1:${server.port}/mcp`);
  client = new Client({ name: "ox-serve-e2e", version: "1" });
  await client.connect(new StreamableHTTPClientTransport(endpoint));
}
async function stop(): Promise<void> {
  await client?.close();
  client = undefined;
  stopServer?.();
  stopServer = undefined;
  await sessions?.close();
  sessions = undefined;
}
async function call(name: string, args: Record<string, unknown> = {}): Promise<any> {
  const response = await client!.callTool({ name, arguments: args });
  check(!response.isError, `${name}: ${JSON.stringify(response.content)}`);
  const content = response.content as { type: string; text: string }[];
  return JSON.parse(content[0]!.text);
}
async function rejected(name: string, args: Record<string, unknown>): Promise<void> {
  const response = await client!.callTool({ name, arguments: args });
  check(response.isError, `${name} should have rejected`);
}
try {
  await start();
  const tools = await client!.listTools();
  check(tools.tools.length === 7, "Expected seven tools");
  check(tools.tools.every((tool) => !tool.name.startsWith("pi_")), "Unexpected prefix");
  await rejected("create_session", { cwd: "/" });
  const created = await call("create_session", { cwd: directory, name: "MCP lifecycle E2E" });
  const id = created.sessionId;
  const initial = await call("read_session", { sessionId: id });
  check(initial.running && !initial.state.isStreaming, "Expected idle real Pi process");
  const resumed = await Promise.all([call("resume_session", { sessionId: id }), call("resume_session", { sessionId: id })]);
  check(resumed.every((item) => item.runtimeId === created.runtimeId), "Resume spawned duplicate process");
  const mutation = { sessionId: id, runtimeId: created.runtimeId, commandId: randomUUID() };
  await rejected("stop_session", { ...mutation, runtimeId: randomUUID() });
  mutation.commandId = randomUUID();
  const stopped = await call("stop_session", mutation);
  check(stopped.stopped, "Stop failed");
  check(JSON.stringify(stopped) === JSON.stringify(await call("stop_session", mutation)), "Deduplication failed");
  await rejected("send_message", { ...mutation, message: "Do not execute", intent: "prompt" });
  await rejected("respond_to_interaction", { ...mutation, commandId: randomUUID(), interactionId: "expired", response: { cancelled: true } });
  const resource = await client!.readResource({ uri: `ox://sessions/${id}` });
  check(resource.contents.length === 1, "Resource read failed");
  const origin = await fetch(endpoint, { method: "POST", headers: { Origin: "https://untrusted.example" }, body: "{}" });
  check(origin.status === 403, "Browser origin was not rejected");
  const invalidHost = await fetch(endpoint, { headers: { Host: "untrusted.example" } });
  check(invalidHost.status === 403, "Untrusted host was not rejected");
  if (Bun.argv.includes("--prompt")) {
    const sent = await call("send_message", { ...mutation, commandId: randomUUID(), message: "Reply exactly OX_SERVE_OK. Do not use tools.", intent: "prompt" });
    check(sent.disposition === "started", "Prompt was not accepted");
    for (let attempt = 0; attempt < 120; attempt++) {
      const snapshot = await call("read_session", { sessionId: id });
      if (!snapshot.state.isStreaming && !snapshot.state.isCompacting && snapshot.state.pendingMessageCount === 0) {
        check(snapshot.messages.some((message: any) => message.role === "assistant" && message.content?.some((block: any) => block.type === "text" && block.text.includes("OX_SERVE_OK"))), "No expected assistant reply");
        break;
      }
      check(attempt < 119, "Model run did not settle");
      await Bun.sleep(500);
    }
  }
  await client!.close();
  client = new Client({ name: "reconnected", version: "1" });
  await client.connect(new StreamableHTTPClientTransport(endpoint));
  check((await call("read_session", { sessionId: id })).runtimeId === created.runtimeId, "Disconnect killed Pi");
  await stop();
  await start();
  const saved = await call("list_sessions");
  check(saved.sessions.some((session: any) => session.sessionId === id && !session.running), "Saved session did not survive restart");
  const restored = await call("resume_session", { sessionId: id });
  check(restored.runtimeId !== created.runtimeId, "Resume should create a new runtime");
  if (Bun.argv.includes("--prompt")) {
    const history = await call("read_session", { sessionId: id });
    check(history.messages.some((message: any) => message.role === "assistant" && message.content?.some((block: any) => block.type === "text" && block.text.includes("OX_SERVE_OK"))), "Assistant history did not survive restart");
  }
  console.log("PASS: real MCP/Pi lifecycle, deduplication, stale targets, persistence, reconnect, resources, and ingress checks");
} finally {
  await stop();
  await rm(directory, { recursive: true, force: true });
}
