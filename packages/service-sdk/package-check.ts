import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import packageMetadata from "./package.json";

type PackReport = {
  name: string;
  version: string;
  filename: string;
  size: number;
  unpackedSize: number;
  files: Array<{ path: string }>;
};

const expectedFiles = [
  "LICENSE",
  "README.md",
  "package.json",
  "src/action-lib.ts",
  "src/action.ts",
  "src/catalog.ts",
  "src/manifest.ts",
  "src/repository.ts",
  "src/skills.ts",
  "src/testing/replay/fixtures.ts",
  "src/testing/replay/proxy.ts",
  "src/testing/replay/types.ts",
].sort();
const outputArgument = process.argv.indexOf("--output");
if (outputArgument >= 0 && !process.argv[outputArgument + 1]) throw new Error("--output requires a directory");
const temporaryRoot = await mkdtemp(join(tmpdir(), "openox-service-sdk-package-check-"));
const packageDirectory = outputArgument >= 0 ? resolve(process.argv[outputArgument + 1]!) : join(temporaryRoot, "package");
const installDirectory = join(temporaryRoot, "install");

try {
  const [packageLicense, repositoryLicense] = await Promise.all([
    readFile(join(import.meta.dir, "LICENSE"), "utf8"),
    readFile(resolve(import.meta.dir, "../../LICENSE"), "utf8"),
  ]);
  if (packageLicense !== repositoryLicense) throw new Error("service-sdk/LICENSE differs from the repository LICENSE");
  await mkdir(packageDirectory, { recursive: true });
  const packed = await run(["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", packageDirectory], import.meta.dir);
  const reports = JSON.parse(packed) as PackReport[];
  const report = reports[0];
  if (!report || reports.length !== 1) throw new Error("npm pack did not return exactly one package");
  if (report.name !== packageMetadata.name || report.version !== packageMetadata.version) {
    throw new Error(`packed ${report.name}@${report.version}, expected ${packageMetadata.name}@${packageMetadata.version}`);
  }
  const files = report.files.map(({ path }) => path).sort();
  if (JSON.stringify(files) !== JSON.stringify(expectedFiles)) throw new Error(`unexpected package files: ${files.join(", ")}`);

  const tarball = join(packageDirectory, report.filename);
  await run(["npm", "install", "--prefix", installDirectory, tarball], import.meta.dir);
  const checkPath = join(installDirectory, "check.ts");
  await Bun.write(checkPath, [
    'await import("@openox/service-sdk/action");',
    'await import("@openox/service-sdk/action-lib");',
    'await import("@openox/service-sdk/catalog");',
    'await import("@openox/service-sdk/skills");',
    'await import("@openox/service-sdk/testing/replay/fixtures");',
    'await import("@openox/service-sdk/testing/replay/proxy");',
    'await import("@openox/service-sdk/testing/replay/types");',
    'import { matchesServiceDomain } from "@openox/service-sdk/manifest";',
    'import { repositoryServicePath } from "@openox/service-sdk/repository";',
    'if (!matchesServiceDomain("mail.google.com", "google.com")) throw new Error("manifest API failed");',
    'if (repositoryServicePath("web:example.com") !== "web/example.com") throw new Error("repository API failed");',
  ].join("\n"));
  await run(["bun", checkPath], installDirectory);
  console.log(`PASS ${report.name}@${report.version} ${report.size} bytes packed, ${report.unpackedSize} bytes unpacked`);
  if (outputArgument >= 0) console.log(`Tarball ${tarball}`);
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}

async function run(command: string[], cwd: string): Promise<string> {
  const child = Bun.spawn({ cmd: command, cwd, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (exitCode !== 0) throw new Error(`${command.join(" ")} exited ${exitCode}${stderr ? `\n${stderr.trimEnd()}` : ""}`);
  return stdout;
}
