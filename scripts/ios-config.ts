import { resolve } from "node:path";
import { parseArgs } from "node:util";
import { ROOT } from "./lib.ts";

export function iosConfiguration(teamValue: string | undefined, bundleValue: string | undefined): string {
  const team = teamValue?.trim();
  if (!team || !/^[A-Z0-9]{10}$/.test(team)) throw new Error("Pass --team with your 10-character Apple Developer Team ID");

  const bundle = bundleValue === undefined ? `ai.openox.local.${team}` : bundleValue.trim();
  if (!/^[A-Za-z0-9]+(?:[.-][A-Za-z0-9-]+)+$/.test(bundle)) throw new Error("Pass --bundle with a reverse-DNS bundle identifier");

  return [
    `OX_DEVELOPMENT_TEAM = ${team}`,
    `OX_BUNDLE_IDENTIFIER = ${bundle}`,
    `OX_APP_GROUP_IDENTIFIER = group.${bundle}`,
    `OX_ICLOUD_CONTAINER_IDENTIFIER = iCloud.${bundle}`,
    `OX_KEYCHAIN_SERVICE = ${bundle}.llm`,
    `OX_WEBSITE_DATA_NAMESPACE = ${bundle}.web-profile`,
    "OX_AGENT_SKILL_TYPE_IDENTIFIER = ai.openox.agent-skill",
    "OX_CHAT_TYPE_IDENTIFIER = ai.openox.chat",
    "",
  ].join("\n");
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    args: Bun.argv.slice(2),
    options: {
      team: { type: "string" },
      bundle: { type: "string" },
    },
    strict: true,
  });

  const path = resolve(ROOT, "ios", "Local.xcconfig");
  await Bun.write(path, iosConfiguration(values.team, values.bundle));
  console.log(`Wrote ${path}`);
}

if (import.meta.main) await main();
