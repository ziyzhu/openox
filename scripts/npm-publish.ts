import { basename, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT } from "./lib.ts";

const packageNames = {
  "ox-cli": "@openox/cli",
  "service-sdk": "@openox/service-sdk",
  services: "@openox/services",
} as const;

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
const tarball = values.tarball ? resolve(values.tarball) : null;
if (!directory || !(directory in packageNames)) throw new Error("Pass --directory <ox-cli|service-sdk|services>");
if (!tarball || !await Bun.file(tarball).exists()) throw new Error("Pass --tarball <package.tgz>");

const expectedName = packageNames[directory as keyof typeof packageNames];
const metadata = await Bun.file(join(ROOT, directory, "package.json")).json() as { name?: string; version?: string };
if (metadata.name !== expectedName) throw new Error(`${directory}/package.json must be named ${expectedName}`);
if (!metadata.version?.match(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)) throw new Error(`${directory}/package.json has an invalid version`);

const archiveName = `${expectedName.slice(1).replace("/", "-")}-${metadata.version}.tgz`;
if (basename(tarball) !== archiveName) throw new Error(`expected tarball ${archiveName}, received ${basename(tarball)}`);

const bytes = await Bun.file(tarball).arrayBuffer();
const integrity = `sha512-${new Bun.CryptoHasher("sha512").update(bytes).digest("base64")}`;
const packageVersion = `${expectedName}@${metadata.version}`;
const published = await command(["npm", "view", packageVersion, "dist.integrity", "--json"]);

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

const publish = await command([
  "npm",
  "publish",
  tarball,
  "--access",
  "public",
  "--provenance",
  "--ignore-scripts",
  ...(values["dry-run"] ? ["--dry-run"] : []),
], false);
if (publish.code !== 0) throw new Error(`npm publish exited ${publish.code}`);
console.log(`PASS published ${packageVersion}${values["dry-run"] ? " (dry run)" : ""}`);

async function command(args: string[], capture = true): Promise<{ code: number; stdout: string; stderr: string }> {
  const child = Bun.spawn({
    cmd: args,
    cwd: ROOT,
    stdout: capture ? "pipe" : "inherit",
    stderr: capture ? "pipe" : "inherit",
  });
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    capture ? new Response(child.stdout).text() : "",
    capture ? new Response(child.stderr).text() : "",
  ]);
  return { code, stdout, stderr };
}
