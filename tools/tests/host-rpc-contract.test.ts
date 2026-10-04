import { afterEach, expect, test } from "bun:test";
import { HostConnection, HostRPCError } from "../../apps/cli/src/host-connection.ts";
import { HostRPCClient } from "../../apps/cli/src/host-rpc.ts";
import { RPC_VERSION, validateResult } from "../../packages/protocol/src/index.ts";
import fixtures from "../../packages/protocol/fixtures.json";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

const endpoint = process.env.OX_RPC_TEST_ENDPOINT;
test.skipIf(!endpoint)("live Host conforms to shared read-only result and invalid-parameter fixtures", async () => {
  const client = new HostRPCClient(endpoint!);
  const connection = new HostConnection(endpoint!);
  cleanups.push(() => client.close(), () => connection.close());
  const description = await client.describe(5000);
  expect(description.protocols.rpc).toContain(RPC_VERSION);
  for (const method of ["chats.list", "chats.get", "providers.list", "logs.list", "services.list", "vm.inspect", "vm.functions"]) {
    if (description.methods.includes(method)) expect(validateResult(method, await client.call(method, 15000))).toBe(true);
  }
  // Only structurally invalid mutation requests are submitted; they cannot reach handlers.
  for (const fixture of fixtures.params.filter(fixture => !fixture.valid && description.methods.includes(fixture.method))) {
    const error = await connection.request(fixture.method, fixture.params as Record<string, unknown>, 5000).catch(error => error);
    expect(error).toBeInstanceOf(HostRPCError);
    if (!(error instanceof HostRPCError)) throw new Error("Expected a contract rejection");
    expect(error.code).toBe(-32602);
  }
}, 90000);
