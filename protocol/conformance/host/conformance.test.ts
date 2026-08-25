import { expect, test } from "bun:test";
import { Value } from "@sinclair/typebox/value";
import { VMControlRequestSchema, VMControlResponseSchema, VM_PROTOCOL_VERSION } from "../../host/schema.ts";

const fixture = (path: string) => Bun.file(`${import.meta.dir}/${path}`).json();

for (const name of ["inspect-request", "call-request"]) {
  test(`Host protocol accepts ${name}`, async () => {
    expect(Value.Check(VMControlRequestSchema, await fixture(`valid/${name}.json`))).toBe(true);
  });
}

for (const name of ["call-response", "error-response"]) {
  test(`Host protocol accepts ${name}`, async () => {
    expect(Value.Check(VMControlResponseSchema, await fixture(`valid/${name}.json`))).toBe(true);
  });
}

for (const name of ["version-request", "array-arguments-request"]) {
  test(`Host protocol rejects ${name}`, async () => {
    expect(Value.Check(VMControlRequestSchema, await fixture(`invalid/${name}.json`))).toBe(false);
  });
}

test("reference Host uses the published VM protocol version and operations", async () => {
  const [messages, implementation] = await Promise.all([
    Bun.file(`${import.meta.dir}/../../../apps/ios/OpenOx/Host/OxHostProtocolMessages.swift`).text(),
    Bun.file(`${import.meta.dir}/../../../apps/ios/OpenOx/Debug/DebugAgentCommands.swift`).text(),
  ]);
  expect(implementation).toContain(`static let vmProtocolVersion = ${VM_PROTOCOL_VERSION}`);
  for (const operation of ["vmInspect", "vmFunctions", "vmCall", "vmEval"]) {
    expect(messages).toContain(`case ${operation}`);
  }
});
