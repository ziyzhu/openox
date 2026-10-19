import { parseArgs } from "node:util";
import { ROOT, run } from "../../../lib.ts";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    version: { type: "string" },
    "build-id": { type: "string" },
    since: { type: "string" },
    profile: { type: "string" },
    offline: { type: "boolean", default: false },
    help: { type: "boolean", default: false },
  },
  strict: true,
});

if (values.help) {
  console.log(`Usage: bun .agents/skills/release/scripts/ios-inspect.ts [options]
  --version <version>  Intended marketing version; defaults to project.yml
  --build-id <id>      Exact App Store Connect build to inspect; never auto-selected
  --since <git-ref>    Operator-verified source revision of the last released iOS version
  --profile <name>     Existing asc profile; does not change authentication settings
  --offline           Inspect local state only; remote state remains unchecked

Read-only inspection of app 6802224502. Prints JSON to stdout; progress to stderr.
Exit 0: automated inspection has no blockers; 1: blockers or incomplete checks.
No build, upload, staging, submission, release, or repository writes.
Save reports only in a private temporary workspace outside Git.`);
  process.exit(0);
}

type Resource = {
  id: string;
  attributes: Record<string, unknown>;
};
type Listing = { data: Resource[]; links?: { next?: string | null } };
const blockers: string[] = [];
const warnings: string[] = [];
const report: Record<string, unknown> = {
  inspectedAt: new Date().toISOString(),
  app: "6802224502",
  profile: values.profile ?? "asc configured default",
  blockers,
  warnings,
  manualChecks: [
    "Confirm the source revision is reviewed and --since identifies the last released build's source.",
    "Confirm the selected remote build was built from the reviewed revision; this script cannot prove provenance.",
    "Review release-specific notes and translations; nonempty saved notes alone are not approval.",
    "Verify archive versions, signing, storage compatibility, and App Store readiness separately.",
    "App Review submission remains manual; remote mutations require separate authorization.",
  ],
};

async function git(...args: string[]): Promise<string> {
  return (await run(["git", ...args], { capture: true })).stdout.trim();
}

async function asc(args: string[]): Promise<unknown> {
  const command = ["asc", ...(values.profile ? ["--profile", values.profile] : []), ...args];
  console.error(command.join(" "));
  return JSON.parse((await run([...command, "--output", "json"], { capture: true })).stdout);
}

async function list(args: string[]): Promise<Listing> {
  const result = await asc([...args, "--paginate"]) as Listing;
  if (!Array.isArray(result.data) || result.links?.next) {
    throw new Error(`Incomplete listing: ${args.join(" ")}`);
  }
  return result;
}

function compareVersions(a: string, b: string): number {
  if (![a, b].every(value => /^\d+(?:\.\d+){0,2}$/.test(value))) {
    throw new Error(`Cannot compare marketing versions ${a} and ${b}`);
  }
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let index = 0; index < 3; index++) {
    const delta = (left[index] ?? 0) - (right[index] ?? 0);
    if (delta) return delta;
  }
  return 0;
}

try {
  const branch = await git("branch", "--show-current");
  const commit = await git("rev-parse", "HEAD");
  const status = await git("status", "--porcelain=v1", "--untracked-files=all");
  report.source = { branch, commit, status };
  if (branch !== "main") blockers.push("Run from main.");
  if (status) blockers.push("Working tree is not clean; official build/staging requires a clean reviewed revision.");

  const project = await Bun.file(`${ROOT}/apps/ios/project.yml`).text();
  const generated = await Bun.file(`${ROOT}/apps/ios/Ox.xcodeproj/project.pbxproj`).text();
  const sourceVersions = [...project.matchAll(/MARKETING_VERSION:\s*["']?([\d.]+)/g)].map(match => match[1]!);
  const generatedVersions = [...generated.matchAll(/MARKETING_VERSION = ([\d.]+);/g)].map(match => match[1]!);
  const version = values.version ?? sourceVersions[0];
  if (!version || !/^\d+(?:\.\d+){0,2}$/.test(version)) throw new Error("Invalid intended marketing version.");
  report.version = { intended: version, sourceVersions, generatedVersions };
  if (!sourceVersions.length || !generatedVersions.length
    || [...sourceVersions, ...generatedVersions].some(value => value !== version)) {
    blockers.push("All project.yml and generated project MARKETING_VERSION settings must match the intended version.");
  }

  if (values.since) {
    const since = await git("rev-parse", "--verify", "--end-of-options", `${values.since}^{commit}`);
    const ancestor = await run(["git", "merge-base", "--is-ancestor", since, commit], { capture: true, allowFailure: true });
    if (ancestor.code !== 0) throw new Error("--since must be an ancestor of HEAD.");
    report.changes = {
      since,
      provenance: "Operator-supplied; must be confirmed against the last released build.",
      commits: await git("log", "--format=%h %s", `${since}..${commit}`),
      files: await git("diff", "--stat", since, commit),
    };
  } else {
    blockers.push("Pass --since with the verified source revision of the last released iOS build to establish the change range.");
  }

  report.remote = { state: "unchecked" };
  if (values.offline) {
    blockers.push("Offline inspection is provisional; App Store Connect state is unchecked.");
  } else {
    report.ascVersion = (await run(["asc", "--version"], { capture: true })).stdout.trim();
    const remote: Record<string, unknown> = { state: "incomplete" };
    report.remote = remote;
    const versions = await list(["versions", "list", "--app", "6802224502", "--platform", "IOS"]);
    remote.versions = versions;
    const released = versions.data.filter(item => item.attributes.appStoreState === "READY_FOR_SALE"
      || item.attributes.appVersionState === "READY_FOR_DISTRIBUTION")
      .sort((a, b) => compareVersions(String(b.attributes.versionString), String(a.attributes.versionString)))[0];
    remote.latestReleased = released ?? null;
    if (released && compareVersions(version, String(released.attributes.versionString)) <= 0) {
      blockers.push(`Intended version ${version} must exceed latest released version ${released.attributes.versionString}.`);
    }

    const builds = await list(["builds", "list", "--app", "6802224502", "--platform", "IOS",
      "--version", version, "--processing-state", "all"]);
    remote.builds = builds;
    const build = builds.data.find(item => item.id === values["build-id"]);
    remote.selectedBuild = build ?? null;
    if (!values["build-id"]) blockers.push("Select an exact --build-id from the reported builds before staging.");
    else if (!build) blockers.push("Selected build does not belong to the intended iOS version.");
    else if (build.attributes.processingState !== "VALID" || build.attributes.expired !== false) {
      blockers.push("Selected build must be processed (VALID) and unexpired.");
    }

    const selected = versions.data.find(item => item.attributes.versionString === version);
    if (!selected) blockers.push(`Version ${version} does not exist in App Store Connect; no version was created.`);
    const metadataVersion = selected ?? released;
    if (metadataVersion) {
      remote.metadataSource = { id: metadataVersion.id, version: metadataVersion.attributes.versionString,
        purpose: selected ? "intended version" : "released baseline only; not staged metadata" };
      remote.versionDetails = await asc(["versions", "view", "--version-id", metadataVersion.id, "--include-build"]);
      const localizations = await list(["localizations", "list", "--version", metadataVersion.id]);
      remote.localizations = localizations;
      if (!localizations.data.length) blockers.push("No version locales returned; metadata inspection is incomplete.");
      const media: Record<string, unknown> = {};
      remote.media = media;
      for (const localization of localizations.data) {
        const locale = String(localization.attributes.locale);
        if (selected && released && !String(localization.attributes.whatsNew ?? "").trim()) {
          blockers.push(`What's New is empty for ${locale}.`);
        }
        if (locale.startsWith("en") && localization.attributes.promotionalText !== "A self-evolving agent that runs on your phone") {
          blockers.push(`Promotional text differs from approved copy in ${locale}; apply the approved English text during release preparation and verify readback.`);
        }
        media[locale] = {
          screenshots: await asc(["screenshots", "list", "--version-localization", localization.id]),
          previews: await asc(["video-previews", "list", "--version-localization", localization.id]),
        };
      }
    } else {
      blockers.push("No intended or released version is available for metadata inspection.");
    }
    remote.state = "inspected";
  }
} catch (error) {
  blockers.push(error instanceof Error ? error.message : String(error));
}

report.result = blockers.length ? "blocked" : "automated inspection complete; manual checks remain";
console.log(JSON.stringify(report, null, 2));
process.exitCode = blockers.length ? 1 : 0;
