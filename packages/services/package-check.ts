import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { validateRepositoryPackage } from "@openox/protocol/repository";
import packageMetadata from "./package.json";
import { packProtocol } from "../protocol/package-check.ts";

type PackReport = {
  name: string;
  version: string;
  filename: string;
  size: number;
  unpackedSize: number;
  files: Array<{ path: string }>;
};

const outputArgument = process.argv.indexOf("--output");
if (outputArgument >= 0 && !process.argv[outputArgument + 1]) throw new Error("--output requires a directory");
const temporaryRoot = await mkdtemp(join(tmpdir(), "openox-services-package-check-"));
const packageDirectory = outputArgument >= 0 ? resolve(process.argv[outputArgument + 1]!) : join(temporaryRoot, "package");
const installDirectory = join(temporaryRoot, "install");

try {
  const [packageLicense, repositoryLicense] = await Promise.all([
    readFile(join(import.meta.dir, "LICENSE"), "utf8"),
    readFile(resolve(import.meta.dir, "../../LICENSE"), "utf8"),
  ]);
  if (packageLicense !== repositoryLicense) throw new Error("services/LICENSE differs from the repository LICENSE");
  await mkdir(packageDirectory, { recursive: true });
  await run(["bun", "package-build.ts"], import.meta.dir);
  const [packagedManifest, bundledManifest] = await Promise.all([
    readFile(join(import.meta.dir, "dist", "repository", "repository.json"), "utf8"),
    readFile(resolve(import.meta.dir, "../../apps/ios/Ox/Resources/OxServices.bundle/repository.json"), "utf8"),
  ]);
  if (packagedManifest !== bundledManifest) throw new Error("npm repository differs from apps/ios/Ox/Resources/OxServices.bundle");

  const packed = await run(["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", packageDirectory], import.meta.dir);
  const reports = JSON.parse(packed) as PackReport[];
  const report = reports[0];
  if (!report || reports.length !== 1) throw new Error("npm pack did not return exactly one package");
  if (report.name !== packageMetadata.name || report.version !== packageMetadata.version) {
    throw new Error(`packed ${report.name}@${report.version}, expected ${packageMetadata.name}@${packageMetadata.version}`);
  }
  const files = report.files.map(({ path }) => path);
  const unexpected = files.filter((path) => !["LICENSE", "README.md", "package.json", "repository.js", "src/skills.ts"].includes(path)
    && !path.startsWith("dist/repository/"));
  if (unexpected.length) throw new Error(`unexpected package files: ${unexpected.join(", ")}`);
  for (const path of ["dist/repository/repository.json", "src/skills.ts"]) {
    if (!files.includes(path)) throw new Error(`package does not contain ${path}`);
  }
  if (files.some((path) => path.endsWith(".har") || (path.startsWith("dist/") && path.endsWith(".ts")))) {
    throw new Error("package contains source or HAR captures");
  }

  const tarball = join(packageDirectory, report.filename);
  const protocolTarball = await packProtocol(join(temporaryRoot, "protocol"));
  await run(["npm", "install", "--prefix", installDirectory, protocolTarball, tarball], import.meta.dir);
  const checkPath = join(installDirectory, "check.ts");
  await Bun.write(checkPath, [
    'import { mkdir } from "node:fs/promises";',
    'import { join } from "node:path";',
    'import { fileURLToPath } from "node:url";',
    'import { repositoryRoot } from "@openox/services";',
    'import { readSkill, readSkills } from "@openox/services/skills";',
    'const repository = await Bun.file(`${repositoryRoot}/repository.json`).json();',
    'const result = readSkills(repositoryRoot, repository.skills);',
    'if (!result.ok) throw new Error(result.error);',
    'if (result.skills.length !== repository.skills.length) throw new Error("repository skills differ");',
    'const fixtureRoot = join(import.meta.dir, "fixture");',
    'const skillDirectory = join(fixtureRoot, "skills", "example-workflow");',
    'await mkdir(join(skillDirectory, "references"), {recursive:true});',
    `await Bun.write(join(skillDirectory, "SKILL.md"), ${JSON.stringify("---\nname: example-workflow\ndescription: Example workflow\n---\nUse the example service.")});`,
    'await Bun.write(join(skillDirectory, "references", "guide.md"), "Example reference");',
    'const loaded = readSkill(skillDirectory, "example-workflow");',
    'if (loaded.resources["references/guide.md"] !== "Example reference") throw new Error("skill resource loading failed");',
    'const discovered = readSkills(fixtureRoot);',
    'if (!discovered.ok || discovered.skills.length !== 1 || JSON.stringify(discovered.skills[0]) !== JSON.stringify(loaded)) throw new Error("skill discovery failed");',
    'const indexPath = fileURLToPath(import.meta.resolve("@openox/services/repository.json"));',
    'const manifestPath = fileURLToPath(import.meta.resolve("@openox/services/web/github.com/service.json"));',
    'if (!(await Bun.file(indexPath).exists())) throw new Error("repository.json export failed");',
    'if (!(await Bun.file(manifestPath).exists())) throw new Error("web service export failed");',
    'process.stdout.write(repositoryRoot);',
  ].join("\n"));
  const repositoryRoot = await run(["bun", checkPath], installDirectory);
  const raw = JSON.parse(await readFile(join(repositoryRoot, "repository.json"), "utf8"));
  const repository = validateRepositoryPackage(raw);
  if ("error" in repository || repository.services.length === 0) throw new Error("installed repository is invalid or empty");
  console.log(`PASS ${report.name}@${report.version} services=${repository.services.length} skills=${repository.skills.length} ${report.size} bytes packed, ${report.unpackedSize} bytes unpacked`);
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
