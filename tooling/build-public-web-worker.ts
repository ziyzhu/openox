import { ROOT } from "./lib.ts";

const publicWebWorkerEntry = `${ROOT}/tooling/public-web-worker.ts`;
const publicWebWorkerOutput = `${ROOT}/apps/ios/Ox/Host/Services/Web/PublicWeb/PublicWebWorker.js`;

async function buildPublicWebWorker(): Promise<string> {
  const result = await Bun.build({
    entrypoints: [publicWebWorkerEntry],
    target: "browser",
    format: "iife",
    minify: true,
    sourcemap: "none",
  });
  if (!result.success || !result.outputs[0]) {
    throw new Error(`public web worker failed to bundle: ${result.logs.map(String).join("; ")}`);
  }
  return (await result.outputs[0].text()).replace(/[ \t]+$/gm, "");
}

if (import.meta.main) {
  const source = await buildPublicWebWorker();
  await Bun.write(publicWebWorkerOutput, source);
  console.log(`Built ${publicWebWorkerOutput} (${source.length} bytes)`);
}
