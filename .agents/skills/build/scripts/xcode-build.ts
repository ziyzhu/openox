import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../lib.ts";

const targets = {
  macos: ["-project", "apps/macos/OxHost.xcodeproj", "-scheme", "host", "-destination", "platform=macOS"],
  ios: ["-project", "apps/ios/Ox.xcodeproj", "-scheme", "ios", "-destination", "generic/platform=iOS Simulator"],
} as const;

const [target, ...extra] = Bun.argv.slice(2);
if (!(target in targets)) {
  console.error("Usage: bun .agents/skills/build/scripts/xcode-build.ts <macos|ios> [xcodebuild arguments]");
  process.exit(1);
}
if (target === "macos") await run(["xcodegen", "generate", "--spec", "apps/macos/project.yml", "--quiet"]);

const log = join(tmpdir(), `openox-xcodebuild-${target}-${Date.now()}.log`);
const result = await run(["xcodebuild", ...targets[target as keyof typeof targets], "-configuration", "Debug", ...extra, "build"], { capture: true, allowFailure: true });
await Bun.write(log, result.stdout + result.stderr);
if (result.code === 0) {
  console.log(`PASS ${target} build (log: ${log})`);
  process.exit(0);
}
const lines = (result.stdout + result.stderr).split("\n");
const errors = [...new Set(lines.filter(line => /\berror:/.test(line)).map(line => line.replace(/^.*?\/apps\//, "apps/").trim()))];
console.error((errors.length ? errors.slice(0, 40) : lines.slice(-20)).join("\n"));
if (errors.length > 40) console.error(`... ${errors.length - 40} more errors`);
console.error(`FAIL ${target} build exited ${result.code} (log: ${log})`);
process.exit(result.code);
