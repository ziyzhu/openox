import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";

const platforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"] as const;
export type StandalonePlatform = typeof platforms[number];
export const nativePlatform = `${process.platform}-${process.arch}`;

export async function buildStandalone(platform: string, output: string): Promise<string> {
  if (!platforms.includes(platform as StandalonePlatform)) throw new Error(`Unsupported platform: ${platform}`);
  const outputDirectory = resolve(output);
  await mkdir(outputDirectory, { recursive: true });
  const staging = await mkdtemp(join(tmpdir(), "ox-cli-build-"));
  try {
    const target = `bun-${platform}${platform.endsWith("-x64") ? "-baseline" : ""}`;
    await run([
      process.execPath, "build", "--compile", `--target=${target}`, "--minify", "--keep-names", "--sourcemap",
      "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
      join(import.meta.dir, "src/ox.ts"), "--outfile", join(staging, "ox"),
    ]);
    await copyFile(join(import.meta.dir, "LICENSE"), join(staging, "LICENSE"));
    const archiveName = `ox-cli-${platform}.tar.gz`;
    const archive = join(outputDirectory, archiveName);
    await run(["tar", "-czf", archive, "ox", "LICENSE"], staging);
    const checksum = createHash("sha256").update(await readFile(archive)).digest("hex");
    await writeFile(join(outputDirectory, `SHA256SUMS-${platform}`), `${checksum}  ${archiveName}\n`);
    console.log(`Built ${archive}`);
    return archive;
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function run(cmd: string[], cwd = import.meta.dir): Promise<void> {
  const child = Bun.spawn({ cmd, cwd, stdout: "inherit", stderr: "inherit" });
  if (await child.exited !== 0) throw new Error(`Failed: ${cmd[0]}`);
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { platform: { type: "string" }, out: { type: "string" } } });
  if (!values.out) throw new Error("Use --out <directory> to select the release artifact directory");
  await buildStandalone(values.platform ?? nativePlatform, values.out);
}
