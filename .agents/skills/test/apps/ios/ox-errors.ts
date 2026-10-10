import { strict as assert } from "node:assert";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const config = qaCommand({
  usage: "Usage: bun .agents/skills/test/apps/ios/ox-errors.ts --device ox-N --host <ws-url> --chat <idle-QA-chat>\nRequires an installed build and enabled Host. Verifies structured ox errors without changing files, settings, or policies.",
  options: { host: { type: "string" }, chat: { type: "string" } },
});
if (!config.values.device || !config.values.host || !config.values.chat) throw new Error("Pass --device, --host, and --chat explicitly");
const endpoint = new URL(config.values.host);
if (!["ws:", "wss:"].includes(endpoint.protocol) || Number(endpoint.port) !== config.debugPort) throw new Error(`Use the selected simulator's Host on port ${config.debugPort}`);
const evidence = await mkdtemp(join(tmpdir(), "openox-errors-"));
const release = claimSimulator(config.device);
const cli = ["bun", "apps/cli/src/ox.ts", "--host", endpoint.href, "--chat", config.values.chat];
try {
  assert.ok(await requireSimulator(config.device), "Boot the reserved simulator before testing");
  const inspected = await run([...cli, "chat", "inspect", "--json"], { capture: true });
  assert.equal(JSON.parse(inspected.stdout).isBusy, false, "Do not interrupt a running chat");
  const source = `
    const failures = [];
    const calls = [
      ['invalid_argument', () => ox.app.setTheme({ selection: 'invalid', purpose: 'Verify error contract' })],
      ['invalid_argument', () => ox.fs.read({ purpose: "Verify error contract", path: 17 })],
      ['not_found', () => ox.fs.read({ purpose: "Verify error contract", path: 'skills/qa-missing-structured-error/SKILL.md' })],
      ['not_found', () => ox.fs.read({ purpose: "Verify error contract", path: 'artifacts/qa-missing-structured-error.txt' })],
      ['permission_denied', () => ox.fs.write({ purpose: "Verify error contract", path: 'skills/manage-providers/SKILL.md', content: 'must not be written' })],
      ['service_not_attached', () => ox.service.invoke({ name: 'ios:qa-missing-structured-error:missing', purpose: 'Verify error contract' })],
    ];
    for (const [expected, call] of calls) {
      try { await call(); throw new Error('Invalid call unexpectedly succeeded: ' + expected); }
      catch (error) {
        if (error.code !== expected || !(error instanceof Error)) throw error;
        console.error(error);
        failures.push({ expected, error, serialized: JSON.parse(JSON.stringify(error)) });
      }
    }
    const settled = await Promise.allSettled([Promise.resolve().then(() => ox.app.setTheme({ selection: 'invalid', purpose: 'Verify parallel failure' }))]);
    return { failures, parallel: settled[0].reason, help: ox.app.setTheme.help(), aliases: ox.app.setModel === ox.conversation.setModel, theme: await ox.app.theme({ purpose: 'Verify successful call' }) };
  `;
  const result = await run([...cli, "vm", "eval", "--script", source, "--json"], { capture: true });
  await writeFile(join(evidence, "caught.json"), result.stdout);
  const output = JSON.parse(result.stdout);
  assert.equal(output.value.failures.length, 6);
  for (const failure of output.value.failures) {
    assert.equal(failure.error.code, failure.expected);
    assert.deepEqual(Object.keys(failure.error).sort(), ["code", "message", "recovery"]);
    assert.equal(typeof failure.error.message, "string");
    assert.ok(failure.error.recovery.length > 10);
    assert.deepEqual(failure.serialized, failure.error);
  }
  assert.equal(output.value.parallel.code, "invalid_argument");
  assert.ok(output.value.help.includes("selection"));
  assert.equal(output.value.aliases, true);
  assert.equal(typeof output.value.theme.selection, "string");
  assert.equal(output.logs.length, 6);
  for (const log of output.logs) {
    const fields = JSON.parse(log.message.split("\n")[0]);
    assert.ok(fields.code && fields.message && fields.recovery);
  }
  const uncaught = await run([...cli, "vm", "eval", "--script", "await ox.app.setTheme({ selection: 'invalid', purpose: 'Verify uncaught error' });", "--json"], { capture: true, allowFailure: true });
  await writeFile(join(evidence, "uncaught.json"), JSON.stringify(uncaught));
  assert.notEqual(uncaught.code, 0);
  assert.ok((uncaught.stdout + uncaught.stderr).includes('"code":"invalid_argument"'));
  assert.ok((uncaught.stdout + uncaught.stderr).includes('"recovery":'));
  console.log(`PASS structured validation, filesystem, permissions, service attachment, serialization, console, uncaught errors, parallel calls, help, aliases, and successful calls; evidence ${evidence}`);
} finally { release(); }
