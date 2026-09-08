import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateIOSManifest } from "../packages/service-sdk/src/catalog.ts";
import { validateAgainstSchema, validateConcreteOutputSchema } from "../packages/service-sdk/src/manifest.ts";
import manifest from "../repositories/builtin/ios/bluetooth/service.json";

test("Bluetooth catalog validates contracts and requires approval for writes", () => {
  expect(validateIOSManifest("ios:bluetooth", manifest)).not.toHaveProperty("error");
  for (const action of manifest.actions) {
    expect(validateConcreteOutputSchema(action.outputSchema, action.id)).toEqual([]);
  }
  const write = manifest.actions.find((action) => action.id === "write")!;
  expect(write.requireApproval).toBe(true);
  expect(validateAgainstSchema(write.inputSchema, { characteristicID: "test", valueHex: "00ff" }).ok).toBe(true);
  for (const valueHex of ["0", "gg", "0xff", "00 ff", "ff".repeat(513)]) {
    expect(validateAgainstSchema(write.inputSchema, { characteristicID: "test", valueHex }).ok).toBe(false);
  }
  const scan = manifest.actions.find((action) => action.id === "scan")!;
  expect(validateAgainstSchema(scan.inputSchema, { durationSeconds: 16 }).ok).toBe(false);
  expect(validateAgainstSchema(scan.inputSchema, { serviceUUIDs: ["not-a-uuid"] }).ok).toBe(false);
});

test.skipIf(process.platform !== "darwin")("Bluetooth native request and buffer regressions", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-bluetooth-checks-"));
  try {
    const executable = join(directory, "bluetooth-checks");
    const compile = Bun.spawn(["swiftc", "-swift-version", "6", "-parse-as-library", "apps/ios/Ox/Host/Services/Native/BluetoothData.swift", "apps/ios/tests/bluetooth.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const error = await new Response(compile.stderr).text();
    expect(await compile.exited, error).toBe(0);
    const run = Bun.spawn([executable], { stdout: "pipe", stderr: "pipe" });
    const output = await new Response(run.stdout).text();
    const failure = await new Response(run.stderr).text();
    expect(await run.exited, failure).toBe(0);
    expect(output).toContain("Bluetooth checks passed");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60_000);
