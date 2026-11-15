import helpers from "../../skills/evolve/references/helpers.js" with { type: "text" };

const implementation = new Function(helpers + "\nreturn createEmbeddedAutomation;")().toString();

export function embedServiceAutomation(path: string, content: string): string {
  if (/^repositories\/[^/]+\/web\/[^/]+\/actions\.js$/.test(path) && !/^\s*function\s+createEmbeddedAutomation\s*\(/.test(content)) {
    return implementation + "\n\n" + content;
  }
  return content;
}
