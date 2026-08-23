import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "./lib.ts";

const tracked = Bun.spawnSync(["git", "ls-files", "--cached", "--others", "--exclude-standard"], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
if (tracked.exitCode !== 0) throw new Error(tracked.stderr.toString().trim() || "git ls-files failed");

const files = tracked.stdout.toString().trim().split("\n").filter(Boolean);
const forbiddenPaths = [
  /^cdk\//,
  /^web\//,
  /^\.github\/workflows\/deploy\.yml$/,
  /^docs\/demo-60s\.md$/,
  /^docs\/LOC\.html$/,
  /^(?!services\/builtin\/web\/[^/]+\/actions\.har$).*\.har$/,
  /\.mitm$/,
  /\.mobileprovision$/,
  /\.p12$/,
];
const forbiddenText = [
  "XK47F7V3VM",
  "540088482516",
  "group.ai.oxcraft.bot",
  "iCloud.ai.oxcraft.bot",
  "github.com/ziyzhu/openox-dev",
];
const failures = files.filter((file) => forbiddenPaths.some((pattern) => pattern.test(file)));

for (const file of files) {
  if (file === "scripts/public-boundary-check.ts") continue;
  const text = await readFile(join(ROOT, file)).catch(() => null);
  if (!text) continue;
  const value = text.toString("utf8");
  for (const forbidden of forbiddenText) {
    if (value.includes(forbidden)) failures.push(`${file}: contains ${forbidden}`);
  }
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(value)) failures.push(`${file}: contains a private key`);
  if (/\bAKIA[0-9A-Z]{16}\b/.test(value)) failures.push(`${file}: contains an AWS access key ID`);
  if (/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/.test(value)) failures.push(`${file}: contains a GitHub token`);
}

if (failures.length > 0) throw new Error(`Public repository boundary failed:\n${[...new Set(failures)].join("\n")}`);
console.log(`PASS public boundary ${files.length} repository files`);
