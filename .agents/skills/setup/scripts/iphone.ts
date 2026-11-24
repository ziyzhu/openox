import { X509Certificate } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT, run } from "../../../lib.ts";

const configPath = "apps/ios/Local.xcconfig";
const exampleTeam = "ABCDE12345";
const exampleBundle = "com.example.openox";
const validTeam = (id: string) => /^[A-Z0-9]{10}$/.test(id) && id !== exampleTeam;
const teamHelp = "Use --team-id <ID>. To find it, see .agents/skills/setup/SKILL.md#build-and-run-on-an-iphone.";

async function signingTeams(): Promise<string[]> {
  const [identities, certificates] = await Promise.all([
    run(["security", "find-identity", "-v", "-p", "codesigning"], { capture: true, allowFailure: true }),
    run(["security", "find-certificate", "-a", "-c", "Apple Development:", "-p"], { capture: true, allowFailure: true }),
  ]);
  const hashes = new Set(Array.from(identities.stdout.matchAll(/^\s*\d+\) ([A-F0-9]{40}) /gim), match => match[1].toUpperCase()));
  const teams = new Set<string>();
  for (const [pem] of certificates.stdout.matchAll(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g)) {
    const certificate = new X509Certificate(pem);
    if (!hashes.has(certificate.fingerprint.replaceAll(":", "").toUpperCase())) continue;
    const team = certificate.subject.match(/^OU=([A-Z0-9]{10})$/m)?.[1];
    if (team && validTeam(team)) teams.add(team);
  }
  return [...teams].sort();
}

async function setup() {
  const { values } = parseArgs({ options: { "team-id": { type: "string" }, help: { type: "boolean", short: "h" } } });
  if (values.help) {
    console.log("Usage: bun run setup:iphone [--team-id <ID>]\n\nPrepare a LocalOnly iPhone build and open the project in Xcode. Existing local configuration is preserved.");
    return;
  }
  if (process.platform !== "darwin") throw new Error("iPhone setup requires a Mac with Xcode.");
  const xcode = await run(["xcodebuild", "-version"], { capture: true, allowFailure: true });
  if (xcode.code !== 0) throw new Error("Install Xcode, launch it once, and select it under Xcode → Settings → Locations → Command Line Tools.");

  const config = Bun.file(resolve(ROOT, configPath));
  if (await config.exists()) {
    const contents = await config.text();
    const team = contents.match(/^[ \t]*OX_DEVELOPMENT_TEAM[ \t]*=[ \t]*([^\s/]+)/m)?.[1];
    const bundle = contents.match(/^[ \t]*OX_BUNDLE_IDENTIFIER[ \t]*=[ \t]*([^\s/]+)/m)?.[1];
    if (team === exampleTeam || bundle === exampleBundle) {
      throw new Error(`${configPath} already exists with example signing values. Replace them for iPhone use; this command will not overwrite the file.`);
    }
    console.log(`Using existing ${configPath}${values["team-id"] ? " (--team-id ignored)" : ""}.`);
  } else {
    let team = values["team-id"];
    if (team === undefined) {
      const teams = await signingTeams();
      if (teams.length) console.log(`Signing team IDs found in local Apple Development certificates: ${teams.join(", ")}.`);
      if (!process.stdin.isTTY) throw new Error(teamHelp);
      if (!teams.length) console.log(`No local Apple Development signing identity found. ${teamHelp}`);
      team = prompt("Signing team ID:", teams.length === 1 ? teams[0] : undefined)?.trim();
    }
    if (!team || !validTeam(team)) throw new Error(`Enter a real 10-character signing team ID. ${teamHelp}`);
    const bundle = `dev.openox.local-${crypto.randomUUID()}`;
    const template = await Bun.file(resolve(ROOT, "apps/ios/LocalOnly.xcconfig.example")).text();
    await writeFile(resolve(ROOT, configPath), template.replace(exampleTeam, team).replace(exampleBundle, bundle), { flag: "wx" });
    console.log(`Created ${configPath} with bundle ID ${bundle}.`);
  }

  await run(["bun", "run", "build:services"]);
  await run(["bun", "run", "build:agent"]);
  await run(["open", "-a", "Xcode", "apps/ios/Ox.xcodeproj"]);
  console.log("In Xcode, select the connected iPhone in the ios scheme and press ⌘R. Trust the Mac and enable Developer Mode if prompted.");
}

if (import.meta.main) {
  try {
    await setup();
  } catch (error) {
    console.error(`iPhone setup: ${(error as Error).message}`);
    process.exitCode = 1;
  }
}
