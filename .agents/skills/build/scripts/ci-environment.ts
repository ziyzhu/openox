import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import config from "../../../../.github/ci.json";

const root = resolve(import.meta.dir, "../../../..");
const environment = Bun.argv[2];
const environments = {
  portable: ["git", "node", "npm"],
  standalone: ["git", "curl", "tar"],
  native: ["git", "xcodebuild", "xcodegen"],
  full: ["git", "node", "npm", "curl", "tar", "xcodebuild", "xcodegen"],
} as const;
if (!(environment in environments)) throw new Error(`Unknown CI environment: ${environment}`);
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
if ((environment === "native" || environment === "full") && process.platform !== "darwin") {
  throw new Error("Native CI requires macOS");
}
for (const tool of environments[environment as keyof typeof environments]) {
  if (!Bun.which(tool)) throw new Error(`Missing prerequisite: ${tool}`);
}
if (environment === "portable" || environment === "full") {
  requireVersion("Node.js", version(["node", "--version"]).replace(/^v/, ""), config.node);
  requireVersion("npm", version(["npm", "--version"]), config.npm);
}
if (environment === "standalone" || environment === "full") {
  if (!config.cli.some(entry => entry.platform === platform)) throw new Error(`Unsupported CLI verification platform: ${platform}`);
}
if (environment === "native" || environment === "full") {
  const xcode = version(["xcodebuild", "-version"]).match(/^Xcode (\S+)/)?.[1];
  if (xcode !== config.xcode) throw new Error(`CI requires Xcode ${config.xcode}; found ${xcode ?? "unknown"}. Select the required Xcode with DEVELOPER_DIR or xcode-select.`);
}
console.log(`PASS CI environment: ${environment}, ${platform}, Bun ${Bun.version}`);
