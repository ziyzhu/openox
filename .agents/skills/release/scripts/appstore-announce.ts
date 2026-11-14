import { parseArgs } from "node:util";
import { run } from "../../../lib.ts";

const APP_ID = "6802224502";
const APP_STORE_URL = `https://apps.apple.com/app/id${APP_ID}`;
const REPOSITORY_URL = "https://github.com/ziyzhu/openox";
const TAG_PREFIX = "ios-v";
const API = "https://api.appstoreconnect.apple.com/v1";

const MODES = ["dry-run", "test", "tag", "announce"] as const;
type Mode = typeof MODES[number];
type Version = { id: string; versionString: string };
type Outcome =
  | { kind: "nothing_live" }
  | { kind: "already_announced"; version: string }
  | { kind: "dry_run"; version: string; message: unknown }
  | { kind: "tested"; version: string }
  | { kind: "tagged"; version: string; commit: string }
  | { kind: "announced"; version: string };

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    mode: { type: "string", default: "dry-run" },
    version: { type: "string" },
  },
  strict: true,
});

const mode = MODES.find((candidate) => candidate === values.mode);
if (!mode) throw new Error(`--mode must be one of ${MODES.join(", ")}`);

function env(name: string): string {
  const value = Bun.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function base64url(bytes: ArrayBuffer | Uint8Array | string): string {
  return Buffer.from(typeof bytes === "string" ? bytes : new Uint8Array(bytes)).toString("base64url");
}

async function token(): Promise<string> {
  const pem = env("ASC_PRIVATE_KEY").replace(/-----[A-Z ]+-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Buffer.from(pem, "base64"), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env("ASC_KEY_ID"), typ: "JWT" }));
  const payload = base64url(JSON.stringify({ iss: env("ASC_ISSUER_ID"), iat: now, exp: now + 600, aud: "appstoreconnect-v1" }));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${base64url(signature)}`;
}

async function asc<T>(path: string, jwt: string): Promise<T> {
  const response = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${jwt}` } });
  if (!response.ok) throw new Error(`App Store Connect ${path} returned ${response.status}: ${await response.text()}`);
  return await response.json() as T;
}

function compare(a: string, b: string): number {
  const [left, right] = [a, b].map((value) => value.split(".").map(Number));
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const delta = (left[index] ?? 0) - (right[index] ?? 0);
    if (delta !== 0) return delta;
  }
  return 0;
}

async function liveVersion(jwt: string): Promise<Version | null> {
  type Response = { data: { id: string; attributes: { versionString: string; appVersionState: string } }[] };
  const { data } = await asc<Response>(`/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=200`, jwt);
  const live = data
    .filter((entry) => entry.attributes.appVersionState === "READY_FOR_DISTRIBUTION")
    .map((entry) => ({ id: entry.id, versionString: entry.attributes.versionString }))
    .filter((entry) => !values.version || entry.versionString === values.version)
    .sort((a, b) => compare(b.versionString, a.versionString));
  return live[0] ?? null;
}

async function whatsNew(version: Version, jwt: string): Promise<string> {
  type Response = { data: { attributes: { locale: string; whatsNew: string | null } }[] };
  const { data } = await asc<Response>(`/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`, jwt);
  const english = data.find((entry) => entry.attributes.locale === "en-US") ?? data.find((entry) => entry.attributes.locale.startsWith("en"));
  const text = english?.attributes.whatsNew?.trim();
  if (!text) throw new Error(`${version.versionString} has no English What's New text`);
  return text;
}

async function sourceCommit(version: Version, jwt: string): Promise<string | null> {
  type Build = { data: { id: string; attributes: { version: string } } | null };
  type Product = { data: { id: string } };
  type Runs = { data: { id: string; attributes: { number: number; sourceCommit: { commitSha: string } | null } }[] };
  type RunBuilds = { data: { id: string }[] };
  const { data: build } = await asc<Build>(`/appStoreVersions/${version.id}/build`, jwt);
  if (!build) return null;
  const { data: product } = await asc<Product>(`/apps/${APP_ID}/ciProduct`, jwt);
  const runs = await asc<Runs>(`/ciProducts/${product.id}/buildRuns?limit=200&sort=-number&fields[ciBuildRuns]=number,sourceCommit`, jwt);
  const run = runs.data.find((entry) => String(entry.attributes.number) === build.attributes.version);
  if (!run?.attributes.sourceCommit) return null;
  const builds = await asc<RunBuilds>(`/ciBuildRuns/${run.id}/builds`, jwt);
  return builds.data.some((entry) => entry.id === build.id) ? run.attributes.sourceCommit.commitSha : null;
}

async function pushTag(version: string, commit: string): Promise<void> {
  await run(["git", "fetch", "--depth=1", "origin", commit]);
  await run(["git", "push", "origin", `${commit}:refs/tags/${TAG_PREFIX}${version}`]);
}

async function newestAnnounced(): Promise<string | null> {
  const { stdout } = await run(["git", "ls-remote", "--tags", "origin", `refs/tags/${TAG_PREFIX}*`], { capture: true });
  const versions = stdout.split("\n").map((line) => line.split(`refs/tags/${TAG_PREFIX}`)[1]).filter(Boolean);
  return versions.sort(compare).at(-1) ?? null;
}

async function appIcon(): Promise<string> {
  const response = await fetch(`https://itunes.apple.com/lookup?id=${APP_ID}`);
  if (!response.ok) throw new Error(`App Store lookup returned ${response.status}`);
  const { results } = await response.json() as { results: { artworkUrl512?: string }[] };
  const icon = results[0]?.artworkUrl512;
  if (!icon) throw new Error("App Store lookup returned no icon");
  return icon;
}

function message(version: string, notes: string, icon: string, commit: string | null) {
  return {
    embeds: [{
      title: `🐂 Ox iOS ${version} is on the App Store`,
      url: APP_STORE_URL,
      thumbnail: { url: icon },
      description: notes.slice(0, 4000),
      fields: commit ? [{ name: "Commit", value: `[${commit.slice(0, 8)}](${REPOSITORY_URL}/commit/${commit})` }] : [],
      color: 0x0a84ff,
    }],
  };
}

async function post(webhook: string, body: unknown): Promise<void> {
  const response = await fetch(`${webhook}?wait=true`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`Discord returned ${response.status}: ${await response.text()}`);
}

async function announce(mode: Mode): Promise<Outcome> {
  const jwt = await token();
  const version = await liveVersion(jwt);
  if (!version) return { kind: "nothing_live" };
  const tags = mode === "tag" || mode === "announce";
  if (tags) {
    const announced = await newestAnnounced();
    if (announced && compare(version.versionString, announced) <= 0) {
      return { kind: "already_announced", version: version.versionString };
    }
  }
  const commit = await sourceCommit(version, jwt);
  console.log(JSON.stringify({ event: "appstore_announce_source", version: version.versionString, commit }));
  if (tags && !commit) throw new Error(`${version.versionString} has no Xcode Cloud source commit to tag`);
  if (mode === "tag") {
    await pushTag(version.versionString, commit!);
    return { kind: "tagged", version: version.versionString, commit: commit! };
  }
  const body = message(version.versionString, await whatsNew(version, jwt), await appIcon(), commit);
  if (mode === "dry-run") return { kind: "dry_run", version: version.versionString, message: body };
  if (mode === "test") {
    await post(env("DISCORD_TEST_WEBHOOK_URL"), body);
    return { kind: "tested", version: version.versionString };
  }
  await post(env("DISCORD_WEBHOOK_URL"), body);
  await pushTag(version.versionString, commit!);
  return { kind: "announced", version: version.versionString };
}

console.log(JSON.stringify({ event: "appstore_announce", mode, ...await announce(mode) }));
