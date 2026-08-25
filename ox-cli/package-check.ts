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

const expectedFiles = ["LICENSE", "README.md", "dist/ox.js", "package.json"];
const outputArgument = process.argv.indexOf("--output");
if (outputArgument >= 0 && !process.argv[outputArgument + 1]) throw new Error("--output requires a directory");
const temporaryRoot = await mkdtemp(join(tmpdir(), "ox-cli-package-check-"));
const packageDirectory = outputArgument >= 0 ? resolve(process.argv[outputArgument + 1]!) : join(temporaryRoot, "package");
const installDirectory = join(temporaryRoot, "install");

try {
  const [packageLicense, repositoryLicense] = await Promise.all([
    readFile(join(import.meta.dir, "LICENSE"), "utf8"),
    readFile(resolve(import.meta.dir, "../LICENSE"), "utf8"),
  ]);
  if (packageLicense !== repositoryLicense) throw new Error("ox-cli/LICENSE differs from the repository LICENSE");
  await mkdir(packageDirectory, { recursive: true });
  await run(["bun", "build.ts"], import.meta.dir);
  const bundle = await readFile(join(import.meta.dir, "dist", "ox.js"), "utf8");
  if (!bundle.startsWith("#!/usr/bin/env bun\n")) throw new Error("dist/ox.js is missing its Bun executable shebang");
  if (bundle.includes(resolve(import.meta.dir, ".."))) throw new Error("dist/ox.js contains an absolute repository path");
  const packed = await run(["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", packageDirectory], import.meta.dir);
  const reports = JSON.parse(packed) as PackReport[];
  const report = reports[0];
  if (!report || reports.length !== 1) throw new Error("npm pack did not return exactly one package");
  if (report.name !== packageMetadata.name || report.version !== packageMetadata.version) {
    throw new Error(`packed ${report.name}@${report.version}, expected ${packageMetadata.name}@${packageMetadata.version}`);
  }
  const files = report.files.map(({ path }) => path).sort();
  if (JSON.stringify(files) !== JSON.stringify(expectedFiles)) {
    throw new Error(`unexpected package files: ${files.join(", ")}`);
  }

  const tarball = join(packageDirectory, report.filename);
  await run(["npm", "install", "--global", "--prefix", installDirectory, tarball], import.meta.dir);
  const executable = process.platform === "win32" ? join(installDirectory, "ox.cmd") : join(installDirectory, "bin", "ox");
  const version = (await run([executable, "--version"], resolve(import.meta.dir, ".."))).trim();
  if (version !== packageMetadata.version) throw new Error(`installed ox reported version ${JSON.stringify(version)}`);
  const help = await run([executable, "--help"], resolve(import.meta.dir, ".."));
  if (!help.includes("Inspect a Profile, create skills, and exercise services")) throw new Error("installed ox help was incomplete");
  const services = JSON.parse(await run([
    executable,
    "--repository",
    resolve(import.meta.dir, "../examples/service-repository"),
    "service",
    "list",
    "--json",
  ], resolve(import.meta.dir, ".."))) as Array<{ domain?: string }>;
  if (!services.some(({ domain }) => domain === "example.com")) throw new Error("installed ox could not inspect the example repository");
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
