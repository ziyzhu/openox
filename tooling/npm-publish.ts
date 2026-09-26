import { basename, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT, run } from "./lib.ts";

const packages: Record<string, { name: string; directory: string }> = {
  cli: { name: "@openox/cli", directory: "apps/cli" },
  "service-sdk": { name: "@openox/service-sdk", directory: "packages/service-sdk" },
  services: { name: "@openox/services", directory: "packages/services" },
};

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    directory: { type: "string" },
    tarball: { type: "string" },
    "dry-run": { type: "boolean", default: false },
  },
  strict: true,
});

const directory = values.directory;
const selected = directory && Object.hasOwn(packages, directory) ? packages[directory] : undefined;
const tarball = values.tarball ? resolve(values.tarball) : null;
if (!selected) throw new Error("Pass --directory <cli|service-sdk|services>");
if (!tarball || !await Bun.file(tarball).exists()) throw new Error("Pass --tarball <package.tgz>");

const expectedName = selected.name;
const metadata = await Bun.file(join(ROOT, selected.directory, "package.json")).json() as { name?: string; version?: string };
if (metadata.name !== expectedName) throw new Error(`${directory}/package.json must be named ${expectedName}`);
if (!metadata.version?.match(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)) throw new Error(`${directory}/package.json has an invalid version`);

const archiveName = `${expectedName.slice(1).replace("/", "-")}-${metadata.version}.tgz`;
if (basename(tarball) !== archiveName) throw new Error(`expected tarball ${archiveName}, received ${basename(tarball)}`);

const bytes = await Bun.file(tarball).arrayBuffer();
const integrity = `sha512-${new Bun.CryptoHasher("sha512").update(bytes).digest("base64")}`;
const packageVersion = `${expectedName}@${metadata.version}`;
const published = await run(["npm", "view", packageVersion, "dist.integrity", "--json"], { capture: true, allowFailure: true });

if (published.code === 0) {
  const publishedIntegrity = JSON.parse(published.stdout) as unknown;
  if (publishedIntegrity !== integrity) throw new Error(`${packageVersion} is already published with different contents`);
  console.log(`PASS ${packageVersion} is already published with matching integrity`);
  process.exit(0);
}

const lookupOutput = `${published.stdout}\n${published.stderr}`;
if (!lookupOutput.includes("E404") && !lookupOutput.includes("404 Not Found")) {
  throw new Error(`failed to query ${packageVersion}\n${lookupOutput.trim()}`);
}

await run([
  "npm",
  "publish",
  tarball,
  "--access",
  "public",
  "--provenance",
  "--ignore-scripts",
  ...(values["dry-run"] ? ["--dry-run"] : []),
]);
console.log(`PASS published ${packageVersion}${values["dry-run"] ? " (dry run)" : ""}`);
