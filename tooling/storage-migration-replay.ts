import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { callHost } from "../apps/cli/src/host-rpc.ts";
import { ROOT } from "./lib.ts";

type ReplayResult = {
  currentVersion?: string;
  versionUpdated?: boolean;
  ordinaryContextRemoved?: boolean;
  unreadableContextRetained?: boolean;
  compactedContextRetained?: boolean;
  compactedContextValid?: boolean;
  noContextPreserved?: boolean;
  transcriptsUnchanged?: boolean;
  secondRunNoOp?: boolean;
  ordinaryExportOmitsContext?: boolean;
  compactedExportRetainsContext?: boolean;
  defaultModelMigrated?: boolean;
  chatModelMigrated?: boolean;
  unsupportedVersionRejected?: boolean;
  providerCatalogMigrated?: boolean;
  actionPoliciesMigrated?: boolean;
  savedServicesMigrated?: boolean;
  futureActionPoliciesPreserved?: boolean;
  actionPolicyResolutionValid?: boolean;
  secretsIndexRenamed?: boolean;
  fixtureResults?: Array<{
    name: string;
    migratedAsExpected: boolean;
    secondRunNoOp: boolean;
  }>;
};

type FixtureEntry = {
  path: string;
  base64: string | null;
};

async function readTree(root: string, directory = root): Promise<FixtureEntry[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: FixtureEntry[] = [];
  for (const entry of entries.sort((first, second) => first.name.localeCompare(second.name))) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push({ path: relative(root, path), base64: null });
      files.push(...await readTree(root, path));
    } else if (entry.isFile()) {
      files.push({
        path: relative(root, path),
        base64: (await readFile(path)).toString("base64"),
      });
    } else {
      throw new Error(`unsupported fixture entry: ${path}`);
    }
  }
  return files;
}

async function readFixtures() {
  const root = join(ROOT, "apps/ios/fixtures/storage-migrations");
  const entries = await readdir(root, { withFileTypes: true });
  return Promise.all(entries
    .filter(entry => entry.isDirectory())
    .sort((first, second) => first.name.localeCompare(second.name))
    .map(async entry => {
      const fixture = join(root, entry.name);
      return {
        name: entry.name,
        before: await readTree(join(fixture, "before")),
        after: await readTree(join(fixture, "after")),
      };
    }));
}

const input = JSON.parse(await readFile(
  join(ROOT, "apps/ios/fixtures/storage-migrations/chat-turns.json"),
  "utf8",
)) as { turns: unknown[] };
const fixtures = await readFixtures();
if (fixtures.length === 0) throw new Error("no storage migration fixtures found");
const result = await callHost("debug.storage.replayMigration", {
  turns: input.turns,
  fixtures,
}, 30_000) as ReplayResult;

const checks = Object.entries(result).filter(([key]) => !["currentVersion", "fixtureResults"].includes(key));
const failures = checks.filter(([, value]) => value !== true).map(([name]) => name);
for (const [name, value] of checks) console.log(`${value === true ? "PASS" : "FAIL"} ${name}`);
for (const fixture of result.fixtureResults ?? []) {
  for (const check of ["migratedAsExpected", "secondRunNoOp"] as const) {
    const passed = fixture[check];
    const name = `fixture.${fixture.name}.${check}`;
    console.log(`${passed ? "PASS" : "FAIL"} ${name}`);
    if (!passed) failures.push(name);
  }
}
if ((result.fixtureResults?.length ?? 0) !== fixtures.length) failures.push("fixtureResults");
const currentFixturePresent = fixtures.some(fixture => fixture.name === result.currentVersion);
console.log(`${currentFixturePresent ? "PASS" : "FAIL"} currentVersionFixture`);
if (!currentFixturePresent) failures.push("currentVersionFixture");
if (failures.length > 0) throw new Error(`storage migration replay failed: ${failures.join(", ")}`);
