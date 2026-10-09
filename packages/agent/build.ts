import { build } from "esbuild";
import ts from "typescript";
import { copyFile, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { defaultSoul } from "./src/core/prompts";
import { nativeGuidanceSource } from "./native-guidance";

function usesNodeRuntime(text: string) {
  const source = ts.createSourceFile("bundle.js", text, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  let found = false;
  const visit = (node: ts.Node) => {
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword
      || ts.isIdentifier(node.expression) && node.expression.text === "require")) found = true;
    if ((ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node))
      && ts.isIdentifier(node.expression) && node.expression.text === "process") found = true;
    if (!found) ts.forEachChild(node, visit);
  };
  visit(source);
  return found;
}

const root = fileURLToPath(new URL("../../", import.meta.url));
const destination = `${root}apps/ios/Ox/Resources/PiDurable.bundle`;
for (const name of ["pi-durable", "pi-ai", "chord"]) {
  const metadata = await Bun.file(new URL("../package.json", import.meta.resolve(`@earendil-works/${name}`))).json();
  if (metadata.version !== "1.0.0") throw new Error(`Unverified ${name} version ${metadata.version}; audit the host adapters before upgrading`);
}
const result = await build({
  absWorkingDir: root,
  entryPoints: { harness: "packages/agent/src/adapters/ios/index.ts", "harness-storage": "packages/agent/src/adapters/ios/storage-diagnostics.ts" },
  bundle: true, platform: "browser", format: "iife", globalName: "OxDurable",
  target: "es2022", minify: true, legalComments: "eof", write: false, metafile: true,
  outdir: destination,
  plugins: [{ name: "native-auth-context", setup(builder) {
    builder.onLoad({ filter: /\/pi-ai\/dist\/auth\/context\.js$/ }, async () => ({
      contents: await Bun.file(`${root}packages/agent/src/adapters/ios/auth-context.ts`).text(),
      loader: "ts", resolveDir: `${root}packages/agent`,
    }));
    // The published tools entry eagerly constructs CodingTools (including bash). Export only iOS-supported tools.
    builder.onLoad({ filter: /\/pi-durable\/dist\/tools\/index\.js$/ }, args => ({
      contents: 'export { createReadTool } from "./read.js"; export { createWriteTool } from "./write.js"; export { createEditTool } from "./edit.js";',
      loader: "js", resolveDir: fileURLToPath(new URL(".", `file://${args.path}`)),
    }));
  } }],
});
const promptResult = await build({
  absWorkingDir: root, entryPoints: { prompts: "packages/agent/src/core/prompt-renderer.ts" },
  bundle: true, platform: "browser", format: "iife", globalName: "OxPrompts",
  target: "es2022", minify: true, legalComments: "eof", write: false, metafile: true, outdir: destination,
});
await mkdir(destination, { recursive: true });
await Promise.all(["harness-proof.js", "agent-files.json"].map(name => rm(`${destination}/${name}`, { force: true })));
const bundles: Record<string, { bytes: number; sha256: string }> = {};
for (const generated of [result, promptResult]) for (const file of generated.outputFiles) {
  const name = file.path.split("/").at(-1)!;
  const output = Object.entries(generated.metafile.outputs).find(([path]) => path.endsWith(`/${name}`))![1];
  const inputs = Object.entries(output.inputs).filter(([, contribution]) => contribution.bytesInOutput > 0).map(([path]) => path);
  const forbidden = inputs.filter(path => /\/(env\/node|storage\/.*\/node|api\/(?!lazy\.js$).*|providers\/|node\/).*\.js$|\/tools\/bash\.js$/.test(path)
    || (name === "harness.js" && /\/(storage-diagnostics\.ts$|storage-check\.ts$|storage-benchmark\.ts$)/.test(path))
    || (name === "harness-storage.js" && /\/src\/(core\/|profile\/|chat-bindings\.ts$|adapters\/ios\/(agent|native-model)\.ts$)/.test(path))
    || (name === "prompts.js" && !/^packages\/(protocol\/src\/skills\.ts|agent\/(skills\/[^?]+|src\/(adapters\/ios\/prompt-renderer|core\/(prompts|provider-prompts|tool-prompts|guidance-texts|bundled-skills|runtime-prompts|host-context|ox-prompts|prompt-renderer))\.ts))$/.test(path)));
  const external = output.imports.filter(item => item.external);
  if (forbidden.length || external.length || usesNodeRuntime(file.text)) {
    throw new Error(`Non-portable ${name}: ${JSON.stringify({ forbidden, external })}`);
  }
  await writeFile(file.path, file.text);
  bundles[name] = { bytes: file.contents.length, sha256: new Bun.CryptoHasher("sha256").update(file.text).digest("hex") };
  console.log(`PASS ${name} audit: ${inputs.length} inputs, ${file.contents.length} bytes, no external imports or Node runtime`);
}
const guidancePath = `${root}apps/ios/Ox/Host/Agent/ModelGuidance.generated.swift`;
const guidanceSource = nativeGuidanceSource();
if (!await Bun.file(guidancePath).exists() || await Bun.file(guidancePath).text() !== guidanceSource) {
  const temporary = `${guidancePath}.${process.pid}.tmp`;
  await writeFile(temporary, guidanceSource);
  await rename(temporary, guidancePath);
}
const resources: Record<string, { bytes: number; sha256: string }> = {};
for (const [name, text] of Object.entries({ "default-soul.md": defaultSoul })) {
  await writeFile(`${destination}/${name}`, text);
  resources[name] = { bytes: new TextEncoder().encode(text).length,
    sha256: new Bun.CryptoHasher("sha256").update(text).digest("hex") };
}
await copyFile(`${root}packages/agent/UPSTREAM_LICENSE.txt`, `${destination}/UPSTREAM_LICENSE.txt`);
await writeFile(`${destination}/manifest.json`, JSON.stringify({
  format: 1, purpose: "isolated-native-rollout", packages: { durable: "1.0.0", ai: "1.0.0", chord: "1.0.0" }, bundles, resources,
}, null, 2) + "\n");
