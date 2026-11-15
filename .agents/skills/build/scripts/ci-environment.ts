import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import config from "../../../../.github/ci.json";

const root = resolve(import.meta.dir, "../../../..");
const mode = Bun.argv[2];
const bun = readFileSync(resolve(root, ".bun-version"), "utf8").trim();
const platform = `${process.platform}-${process.arch}`;

function requireVersion(tool: string, actual: string, expected: string): void {
  if (!Bun.semver.satisfies(actual, expected)) {
    throw new Error(`CI requires ${tool} ${expected}; found ${actual}. Use the required toolchain on this or another machine.`);
  }
}

function version(command: string[]): string {
  const result = Bun.spawnSync(command, { stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) throw new Error(`${command.join(" ")} failed: ${result.stderr.toString().trim()}`);
  return result.stdout.toString().trim();
}

requireVersion("Bun", Bun.version, bun);
if (mode === "portable" || mode === "full") {
  requireVersion("Node.js", version(["node", "--version"]).replace(/^v/, ""), config.node);
  requireVersion("npm", version(["npm", "--version"]), config.npm);
}
if (mode === "standalone" || mode === "full") {
  if (!config.cli.some(entry => entry.platform === platform)) throw new Error(`Unsupported CLI verification platform: ${platform}`);
}
if (mode === "native" || mode === "full") {
  const xcode = version(["xcodebuild", "-version"]).match(/^Xcode (\S+)/)?.[1];
  if (xcode !== config.xcode) throw new Error(`CI requires Xcode ${config.xcode}; found ${xcode ?? "unknown"}. Select the required Xcode with DEVELOPER_DIR or xcode-select.`);
}
console.log(`PASS CI environment: ${mode}, ${platform}, Bun ${Bun.version}`);
