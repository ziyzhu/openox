export async function mcpManagementFixture(request: Request): Promise<Response> {
  const path = new URL(request.url).pathname;
  if (path === "/mcp-fail") return new Response("Unavailable", { status: 503 });
  if (request.method === "DELETE") return new Response(null, { status: 204 });
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const rpc = await request.json() as {
    id?: number;
    method: string;
    params?: { arguments?: { message?: string } };
  };
  if (rpc.id === undefined) return new Response(null, { status: 202 });
  let result: unknown;
  switch (rpc.method) {
    case "initialize":
      result = { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: `MCP QA ${path}`, version: "1.0" } };
      break;
    case "tools/list":
      result = { tools: [{ name: "echo", description: "Return the supplied message", inputSchema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] } }] };
      break;
    case "tools/call":
      result = { content: [{ type: "text", text: rpc.params?.arguments?.message ?? "" }] };
      break;
    default:
      return Response.json({ jsonrpc: "2.0", id: rpc.id, error: { code: -32601, message: "Unknown method" } });
  }
  console.log(JSON.stringify({ fixture: "mcp-management", path, method: rpc.method }));
  return Response.json({ jsonrpc: "2.0", id: rpc.id, result });
}
