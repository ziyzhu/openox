import { runOnce } from "../apps/cli/src/debug-ws.ts";

const response = await runOnce({
  kind: "check-api-services", id: crypto.randomUUID(),
}, 60_000) as {
  result?: { ok: boolean; checks: Record<string, boolean | string> };
};
if (!response.result) throw new Error("API service checks did not return a result");
for (const [name, result] of Object.entries(response.result.checks)) {
  console.log(`${result === true ? "PASS" : "FAIL"} ${name}${typeof result === "string" ? `: ${result}` : ""}`);
}
if (!response.result.ok) throw new Error("API service checks failed");
