import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";

export async function check(): Promise<string> {
  const failures: string[] = [];
  let count = 0;
  for await (const file of new Bun.Glob("apps/{ios,macos,shared}/**/*.swift").scan(ROOT)) {
    const source = await readFile(join(ROOT, file), "utf8");
    count += 1;
    if (/^\s*#(?:if|elseif).*\bos\(/m.test(source)) {
      failures.push(`${file}: select platform implementations through source ownership, not OS conditionals`);
    }
    if (file.startsWith("apps/shared/") && /\b(?:import (?:UIKit|AppKit|BackgroundTasks|MessageUI)|IOSHost|MacHostApplication|IOSConversationExecution|MacConversationExecution|IOSConversationFeedback|MacConversationFeedback|IOSNativeServiceCatalog|MacNativeServiceCatalog|IOSStreamFrameDriver|MacStreamFrameDriver)\b/.test(source)) {
      failures.push(`${file}: shared runtime must not depend on a platform adapter`);
    }
  }
  const macProject = await readFile(join(ROOT, "apps/macos/project.yml"), "utf8");
  const iosProject = await readFile(join(ROOT, "apps/ios/project.yml"), "utf8");
  if (/\.\.\/ios\b|apps\/ios\b/.test(macProject)) failures.push("macOS target must not compile or package iOS sources");
  if (/\.\.\/macos\b|apps\/macos\b/.test(iosProject)) failures.push("iOS target must not compile or package macOS sources");
  if (!macProject.includes("../shared/Host") || !iosProject.includes("../shared/Host")) {
    failures.push("Both targets must explicitly include the neutral shared runtime");
  }
  if (failures.length) throw new Error(`Host platform boundary failed:\n${failures.join("\n")}`);
  return `Host platform boundary ${count} Swift files`;
}

if (import.meta.main) await runCheck(check);
