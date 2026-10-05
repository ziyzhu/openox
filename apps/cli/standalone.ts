import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { crc32, deflateRawSync } from "node:zlib";

const platforms = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "windows-arm64", "windows-x64"] as const;
export type StandalonePlatform = typeof platforms[number];
export const nativePlatform = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;

export function standaloneArtifacts(platform: string): { executable: string; archive: string } {
  return platform.startsWith("windows-")
    ? { executable: "ox.exe", archive: `ox-cli-${platform}.zip` }
    : { executable: "ox", archive: `ox-cli-${platform}.tar.gz` };
}

export async function buildStandalone(platform: string, output: string): Promise<string> {
  if (!platforms.includes(platform as StandalonePlatform)) throw new Error(`Unsupported platform: ${platform}`);
  const outputDirectory = resolve(output);
  await mkdir(outputDirectory, { recursive: true });
  const staging = await mkdtemp(join(tmpdir(), "ox-cli-build-"));
  try {
    const target = `bun-${platform}${platform.endsWith("-x64") ? "-baseline" : ""}`;
    const { executable, archive: archiveName } = standaloneArtifacts(platform);
    await run([
      process.execPath, "build", "--compile", `--target=${target}`, "--minify", "--keep-names", "--sourcemap",
      "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
      join(import.meta.dir, "src/ox.ts"), "--outfile", join(staging, executable),
    ]);
    await copyFile(join(import.meta.dir, "LICENSE"), join(staging, "LICENSE"));
    const archive = join(outputDirectory, archiveName);
    if (archiveName.endsWith(".zip")) await writeZip(archive, staging, [executable, "LICENSE"]);
    else await run(["tar", "-czf", archive, executable, "LICENSE"], staging);
    const checksum = createHash("sha256").update(await readFile(archive)).digest("hex");
    await writeFile(join(outputDirectory, `SHA256SUMS-${platform}`), `${checksum}  ${archiveName}\n`);
    console.log(`Built ${archive}`);
    return archive;
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

// Windows runners ship GNU tar, which cannot write ZIP archives.
async function writeZip(archive: string, directory: string, names: string[]): Promise<void> {
  const local: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;
  for (const name of names) {
    const data = await readFile(join(directory, name));
    const compressed = deflateRawSync(data);
    const header = Buffer.alloc(26);
    header.writeUInt16LE(20, 0);
    header.writeUInt16LE(8, 4);
    header.writeUInt16LE(0x21, 8);
    header.writeUInt32LE(crc32(data), 10);
    header.writeUInt32LE(compressed.length, 14);
    header.writeUInt32LE(data.length, 18);
    header.writeUInt16LE(name.length, 22);
    const entry = Buffer.concat([u32(0x04034b50), header, Buffer.from(name), compressed]);
    central.push(Buffer.concat([u32(0x02014b50), u16(20), header, Buffer.alloc(10), u32(offset), Buffer.from(name)]));
    local.push(entry);
    offset += entry.length;
  }
  const directoryRecords = Buffer.concat(central);
  const end = Buffer.concat([u32(0x06054b50), u32(0), u16(names.length), u16(names.length), u32(directoryRecords.length), u32(offset), u16(0)]);
  await writeFile(archive, Buffer.concat([...local, directoryRecords, end]));
}

function u16(value: number): Buffer { const buffer = Buffer.alloc(2); buffer.writeUInt16LE(value); return buffer; }
function u32(value: number): Buffer { const buffer = Buffer.alloc(4); buffer.writeUInt32LE(value); return buffer; }

async function run(cmd: string[], cwd = import.meta.dir): Promise<void> {
  const child = Bun.spawn({ cmd, cwd, stdout: "inherit", stderr: "inherit" });
  if (await child.exited !== 0) throw new Error(`Failed: ${cmd[0]}`);
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { platform: { type: "string" }, out: { type: "string" } } });
  if (!values.out) throw new Error("Use --out <directory> to select the release artifact directory");
  await buildStandalone(values.platform ?? nativePlatform, values.out);
}
