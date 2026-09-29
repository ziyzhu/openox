import { expect, test } from "bun:test";
import { createMCPHandler } from "../../apps/cli/src/serve.ts";

function request(method: string, params?: Record<string, unknown>): Request {
  return new Request("http://127.0.0.1:8787/mcp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
}

test("MCP exposes only selected Herdr actions and dispatches a validated prompt", async () => {
  const calls: string[][] = [];
  const handler = createMCPHandler(["agent_list", "agent_prompt"], async args => {
    calls.push(args);
    return { ok: true };
  });
  const listed = await (await handler(request("tools/list"))).json();
  expect(listed.result.tools.map((tool: { name: string }) => tool.name)).toEqual(["agent_list", "agent_prompt"]);

  const denied = await (await handler(request("tools/call", { name: "agent_read", arguments: { target: "a" } }))).json();
  expect(denied.result.isError).toBe(true);

  const invalid = await (await handler(request("tools/call", { name: "agent_prompt", arguments: { target: "a", text: "hi", extra: true } }))).json();
  expect(invalid.result.isError).toBe(true);
  expect(calls).toEqual([]);

  const sent = await (await handler(request("tools/call", { name: "agent_prompt", arguments: { target: "a", text: "hi" } }))).json();
  expect(sent.result.structuredContent).toEqual({ result: { ok: true } });
  expect(calls).toEqual([["agent", "prompt", "a", "hi"]]);
});
