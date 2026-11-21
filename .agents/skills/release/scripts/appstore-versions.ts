import { mkdir, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { run } from "../../../lib.ts";

const APP_ID = "6802224502";
const DESTINATION = "s3://openox-service-assets-prod/api/ios/versions";
const ENDPOINT = "https://openox.ai/api/ios/versions";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    out: { type: "string" },
    profile: { type: "string" },
    "aws-profile": { type: "string" },
    help: { type: "boolean", default: false },
  },
  strict: true,
});

if (values.help) {
  console.log(`Usage: bun .agents/skills/release/scripts/appstore-versions.ts [options]
  --out <dir>            Write the files locally and skip the upload
  --profile <name>       Existing asc profile
  --aws-profile <name>   Existing AWS CLI profile

Reads What's New for every released iOS version of app ${APP_ID} from App Store Connect
and uploads ${ENDPOINT} and ${ENDPOINT}/<version>.`);
  process.exit(0);
}

type Resource = { id: string; attributes: Record<string, unknown> };
type VersionNotes = { version: string; notes: Record<string, string[]> };

async function asc(args: string[]): Promise<Resource[]> {
  const command = ["asc", ...(values.profile ? ["--profile", values.profile] : []), ...args, "--output", "json"];
  const { stdout } = await run(command, { capture: true });
  return (JSON.parse(stdout) as { data: Resource[] }).data;
}

function compare(a: string, b: string): number {
  const [left, right] = [a, b].map((value) => value.split(".").map(Number));
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const delta = (left[index] ?? 0) - (right[index] ?? 0);
    if (delta !== 0) return delta;
  }
  return 0;
}

function noteLines(text: string): string[] {
  return text.split("\n").map((line) => line.replace(/^\s*(?:[•\-*]|\d+\.)\s*/, "").trim()).filter(Boolean);
}

async function releasedVersions(): Promise<VersionNotes[]> {
  const versions = await asc(["versions", "list", "--app", APP_ID, "--platform", "IOS", "--limit", "200"]);
  const released = versions.filter((version) => version.attributes.appVersionState === "READY_FOR_DISTRIBUTION");
  const result: VersionNotes[] = [];
  for (const version of released) {
    const localizations = await asc(["localizations", "list", "--version", version.id]);
    const notes = Object.fromEntries(localizations
      .map((localization) => [String(localization.attributes.locale), noteLines(String(localization.attributes.whatsNew ?? ""))] as const)
      .filter(([, lines]) => lines.length > 0)
      .sort(([a], [b]) => a.localeCompare(b)));
    if (Object.keys(notes).length > 0) result.push({ version: String(version.attributes.versionString), notes });
  }
  return result.sort((a, b) => compare(b.version, a.version));
}

const versions = await releasedVersions();
const directory = values.out ?? await mkdtemp(join(tmpdir(), "appstore-versions-"));
await mkdir(join(directory, "versions"), { recursive: true });
await Bun.write(join(directory, "versions.json"), `${JSON.stringify({ versions })}\n`);
for (const version of versions) await Bun.write(join(directory, "versions", version.version), `${JSON.stringify(version)}\n`);

if (!values.out) {
  const aws = ["aws", ...(values["aws-profile"] ? ["--profile", values["aws-profile"]] : []), "s3", "cp"];
  const headers = ["--content-type", "application/json", "--cache-control", "public,max-age=300", "--only-show-errors"];
  await run([...aws, join(directory, "versions"), DESTINATION, "--recursive", ...headers]);
  await run([...aws, join(directory, "versions.json"), DESTINATION, ...headers]);
}

console.log(JSON.stringify({
  event: "appstore_versions",
  uploaded: !values.out,
  destination: values.out ? directory : ENDPOINT,
  count: versions.length,
  newest: versions[0]?.version ?? null,
}));
