import { createHash } from "node:crypto";
import { mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    sources: { type: "string" },
    out: { type: "string" },
    background: { type: "string", default: "#FBE9C7" },
    help: { type: "boolean" },
  },
});
if (values.help) {
  console.log("bun app-store-previews.ts --sources <native-png-directory> --out <external-directory> [--background '#FBE9C7']");
  process.exit(0);
}
if (!values.sources || !values.out) throw new Error("--sources and --out are required");
if (!/^#[\da-f]{6}$/i.test(values.background!)) throw new Error("--background must be a six-digit hex color");

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const output = resolve(values.out);
await mkdir(output, { recursive: true });
const resolvedOutput = await realpath(output);
if (resolvedOutput === root.slice(0, -1) || resolvedOutput.startsWith(root)) {
  throw new Error("Keep generated previews outside the repository");
}
const readme = await readFile(join(root, "README.md"), "utf8");
const features = [...readme.matchAll(/^\d\. \*\*(.+)\*\* — (.+)$/gm)];
if (features.length !== 3) throw new Error("Expected the three canonical README features");
const names = ["01-connect-anything", "02-local-first", "03-yours", "04-memory", "05-reddit-task", "06-assistant-research"];
const titles = [...features.map((match) => match[1]!), "Import memory", "Create services\non the fly", "Research across\nassistants"];
const descriptions = [...features.map((match) => match[2]!), "", "", ""];
const escape = (text: string) => text.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
const manifest = [];
const posters = [];

for (const [index, name] of names.entries()) {
  const source = resolve(values.sources, `${name}.png`);
  const png = await readFile(source);
  if (png.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a") throw new Error(`Expected PNG: ${source}`);
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  if (width < 1000 || Math.abs(width / height - 1206 / 2622) > 0.015) throw new Error(`Expected native portrait iPhone capture: ${source}`);
  const title = titles[index]!;
  const description = descriptions[index]!;
  const poster = `<article class="poster" aria-label="${escape(title.replaceAll("\n", " "))}">
    <header><h1>${escape(title)}</h1>${description ? `<p>${escape(description)}</p>` : ""}</header>
    <figure><img src="data:image/png;base64,${png.toString("base64")}" alt="Ox ${escape(title.replaceAll("\n", " "))}" width="${width}" height="${height}"></figure>
  </article>`;
  posters.push(poster);
  manifest.push({ name, title, description, source, sourceSHA256: createHash("sha256").update(png).digest("hex"), sourceWidth: width, sourceHeight: height, width: 1320, height: 2868, background: values.background, illustrative: index !== 1 });
}

const css = `
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #3A2410; }
.poster {
  width: 1320px; height: 2868px; position: relative; overflow: hidden;
  --tint: ${values.background};
  background: linear-gradient(180deg, color-mix(in srgb, var(--tint) 5%, white) 0%, color-mix(in srgb, var(--tint) 12%, white) 45%, var(--tint) 100%);
}
.poster header { position: absolute; top: 126px; left: 120px; right: 120px; text-align: center; }
.poster h1 { margin: 0; font-size: 76px; font-weight: 600; line-height: 1.16; letter-spacing: -2.2px; white-space: pre-line; }
.poster p { margin: 24px auto 0; max-width: 1050px; font-size: 48px; font-weight: 400; line-height: 1.26; letter-spacing: -.65px; }
.poster figure {
  position: absolute; top: 510px; left: 132px; width: 1056px; margin: 0; padding: 24px;
  border-radius: 154px; background: linear-gradient(180deg, #FFFDF7, #FFF6E6);
  box-shadow: 0 30px 85px #75512e26, 0 5px 20px #75512e12, inset 0 0 0 2px #ffffff;
}
.poster img { display: block; width: 1008px; height: auto; border-radius: 130px; }
.gallery { width: 1320px; padding: 36px 42px; background: #FFF6E6; }
.gallery > header { margin-bottom: 24px; }
.gallery > header h1 { margin: 0; font-size: 30px; font-weight: 600; letter-spacing: -.8px; }
.gallery > header p { margin: 8px 0 0; font-size: 17px; color: #7A5A3A; }
.grid { display: grid; grid-template-columns: repeat(3, 396px); gap: 24px; }
.tile { width: 396px; height: 860.4px; overflow: hidden; border-radius: 36px; }
.tile .poster { transform: scale(.3); transform-origin: top left; }
`;
const document = (title: string, body: string) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escape(title)}</title><style>${css}</style></head><body>${body}</body></html>`;
for (const [index, name] of names.entries()) {
  await writeFile(join(output, `${name}.html`), document(titles[index]!, posters[index]!));
}
await writeFile(join(output, "index.html"), document("Ox App Store previews", `<main class="gallery"><header><h1>Ox · App Store previews</h1><p>Ox palette · 1320 × 2868 · native captures with illustrative conversation content</p></header><section class="grid">${posters.map((poster) => `<div class="tile">${poster}</div>`).join("")}</section></main>`));
await writeFile(join(output, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(JSON.stringify({ output, count: posters.length, background: values.background, width: 1320, height: 2868 }));
