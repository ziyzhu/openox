import { guidanceTexts } from "./src/core/guidance-texts";
import { executeGuidance, countWords } from "./src/core/tool-prompts";

const swiftString = (text: string) => JSON.stringify(text).replace(/\\u([0-9a-f]{4})/gi, "\\u{$1}");

export function nativeGuidanceSource() {
  const entries = Object.entries(guidanceTexts).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([key, value]) => `        ${swiftString(key)}: ${swiftString(value)},`).join("\n");
  const execute = (variant: "ox" | "website") => swiftString(executeGuidance({ catalog: "__OX_CATALOG__", variant,
    timeoutSeconds: 999001, maxLines: 999002, maxBytes: 999003 * 1024, maxFetches: 999004, maxTransientAttachments: 999005 }))
    .replaceAll("__OX_CATALOG__", "\\(catalog)").replaceAll("999001", "\\(timeoutSeconds)")
    .replaceAll("999002", "\\(maxLines)").replaceAll("999003", "\\(maxBytes / 1024)")
    .replaceAll("999004", "\\(word(maxFetches))").replaceAll("999005", "\\(word(maxTransientAttachments))");
  return `nonisolated enum ModelGuidance {
    private static let texts: [String: String] = [
${entries}
    ]

    static func text(_ key: String) -> String {
        guard let text = texts[key] else { preconditionFailure("Unknown model guidance: \\(key)") }
        return text
    }

    private static let words = ${JSON.stringify(countWords)}

    private static func word(_ value: Int) -> String {
        words.indices.contains(value) ? words[value] : String(value)
    }

    static func execute(catalog: String, website: Bool, timeoutSeconds: Int, maxLines: Int, maxBytes: Int, maxFetches: Int, maxTransientAttachments: Int) -> String {
        if website { return ${execute("website")} }
        return ${execute("ox")}
    }
}
`;
}
