import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import packageMetadata from "./package.json";

type PackReport = { name: string; version: string; filename: string; size: number; unpackedSize: number; files: Array<{ path: string }> };

export async function packProtocol(directory: string): Promise<string> {
  const [license, original] = await Promise.all([
    readFile(join(import.meta.dir, "LICENSE"), "utf8"), readFile(resolve(import.meta.dir, "../../LICENSE"), "utf8"),
  ]);
  if (license !== original) throw new Error("protocol/LICENSE differs from the repository LICENSE");
  await mkdir(directory, { recursive: true });
  const reports = JSON.parse(await run(["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", directory], import.meta.dir)) as PackReport[];
  const report = reports[0];
  if (reports.length !== 1 || report?.name !== packageMetadata.name || report.version !== packageMetadata.version) {
    throw new Error("npm pack returned an unexpected protocol package");
  }
  const expected = ["LICENSE", "README.md", "package.json", "src/contract.ts",
    ...Object.values(packageMetadata.exports).map(path => path.replace(/^\.\//, ""))].sort();
  if (JSON.stringify(report.files.map(file => file.path).sort()) !== JSON.stringify(expected)) throw new Error("unexpected protocol package files");
  console.log(`PASS packed ${report.name}@${report.version} ${report.size} bytes packed, ${report.unpackedSize} bytes unpacked`);
  return join(directory, report.filename);
}

if (import.meta.main) {
  const outputArgument = process.argv.indexOf("--output");
  if (outputArgument >= 0 && !process.argv[outputArgument + 1]) throw new Error("--output requires a directory");
  const temporary = await mkdtemp(join(tmpdir(), "openox-protocol-package-check-"));
  try {
    const directory = outputArgument >= 0 ? resolve(process.argv[outputArgument + 1]!) : join(temporary, "package");
    const tarball = await packProtocol(directory);
    const install = join(temporary, "install");
    await run(["npm", "install", "--prefix", install, tarball], import.meta.dir);
    const script = join(install, "check.ts");
    await Bun.write(script, [
      'import { RPC_VERSION, validateParams } from "@openox/protocol";',
      'import { validateRepositoryPackage } from "@openox/protocol/repository";',
      'import { matchesServiceDomain } from "@openox/protocol/manifest";',
      'import { inspectInstaller } from "@openox/protocol/installer";',
      'await import("@openox/protocol/action");',
      'await import("@openox/protocol/catalog");',
      'await import("@openox/protocol/model-actions");',
      'await import("@openox/protocol/skills");',
      'if (RPC_VERSION !== 1 || !validateParams("host.describe", {})) throw new Error("RPC API failed");',
      'const repository = validateRepositoryPackage({version:3,name:"Example",services:["web:example.com"],skills:[]});',
      'if ("error" in repository) throw new Error(repository.error);',
      'if (!matchesServiceDomain("mail.example.com", "example.com")) throw new Error("manifest API failed");',
      `if (inspectInstaller(${JSON.stringify('window.ox.install(({action})=>action("example",{invoke(){return {}}}))')},{actions:[{id:"example"}]}).length) throw new Error("installer API failed");`,
      'for (const name of ["schema.json","methods.json","fixtures.json","repository.schema.json"]) await import(`@openox/protocol/${name}`);',
    ].join("\n"));
    await run(["bun", script], install);
    console.log("PASS installed protocol package: Client-Host and Host-Repository exports");
    if (outputArgument >= 0) console.log(`Tarball ${tarball}`);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function run(command: string[], cwd: string): Promise<string> {
  const child = Bun.spawn({ cmd: command, cwd, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  if (code !== 0) throw new Error(`${command.join(" ")} exited ${code}\n${stderr.trimEnd()}`);
  return stdout;
}
