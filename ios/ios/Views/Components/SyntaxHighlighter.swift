import SwiftUI
import UIKit

enum SyntaxHighlighter {
    private struct Rule { let pattern: String; let color: DynamicColor }
    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 256
        c.totalCostLimit = TextRenderCachePolicy.attributedLimit
        return c
    }()

    static func highlight(_ source: String, language: String?) -> AttributedString {
        let key = TextRenderCachePolicy.key("\(language ?? "")\u{1}\(source)")
        if let hit = cache.object(forKey: key) { return hit.value }
        let result = render(source, language: language)
        let cost = TextRenderCachePolicy.attributedCost(utf16Count: source.utf16.count)
        if cost <= cache.totalCostLimit {
            cache.setObject(Box(result), forKey: key, cost: cost)
        }
        return result
    }

    static func selectable(_ source: String, language: String?, font: UIFont) -> NSAttributedString {
        let key = TextRenderCachePolicy.key("\(font.fontName)|\(font.pointSize)|\(language ?? "")\u{1}\(source)")
        if let hit = selectableCache.object(forKey: key) { return hit }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .pushOut
        let rendered = NSMutableAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ])
        applyRules(to: source, language: language) { range, color in
            rendered.addAttribute(.foregroundColor, value: color.uiColor, range: range)
        }
        let result = NSAttributedString(attributedString: rendered)
        let cost = TextRenderCachePolicy.attributedCost(utf16Count: result.length)
        if cost <= selectableCache.totalCostLimit {
            selectableCache.setObject(result, forKey: key, cost: cost)
        }
        return result
    }

    private static let selectableCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 256
        c.totalCostLimit = TextRenderCachePolicy.attributedLimit
        return c
    }()

    private static func render(_ source: String, language: String?) -> AttributedString {
        var attr = AttributedString(source)
        attr.foregroundColor = .primary
        applyRules(to: source, language: language) { range, color in
            if let r = Range(range, in: source),
               let ar = Range(r, in: attr) {
                attr[ar].foregroundColor = color.dynamic
            }
        }
        return attr
    }

    private static func applyRules(
        to source: String,
        language: String?,
        apply: (NSRange, DynamicColor) -> Void
    ) {
        let rules = rules(for: language?.lowercased())
        guard !rules.isEmpty else { return }
        let ns = source as NSString
        var claimed = IndexSet()
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard range.location != NSNotFound else { return }
                let span = range.location..<(range.location + range.length)
                guard !claimed.contains(integersIn: span) else { return }
                claimed.insert(integersIn: span)
                apply(range, rule.color)
            }
        }
    }

    private static func rules(for language: String?) -> [Rule] {
        let comment = DynamicColor(light: 0x5D6C79, dark: 0x6C7986)
        let string = DynamicColor(light: 0xC41A16, dark: 0xFC6A5D)
        let keyword = DynamicColor(light: 0x9B2393, dark: 0xFC5FA3)
        let number = DynamicColor(light: 0x1C00CF, dark: 0xD0BF69)
        let key = DynamicColor(light: 0x326D74, dark: 0x67B7A4)

        switch language {
        case "json":
            return [
                Rule(pattern: #""(?:[^"\\]|\\.)*"(?=\s*:)"#, color: key),
                Rule(pattern: #""(?:[^"\\]|\\.)*""#, color: string),
                Rule(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: number),
                Rule(pattern: #"\b(?:true|false|null)\b"#, color: keyword),
            ]
        case "python", "py":
            return [
                Rule(pattern: #"#[^\n]*"#, color: comment),
                Rule(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, color: string),
                Rule(pattern: #"f"(?:[^"\\]|\\.)*"|f'(?:[^'\\]|\\.)*'"#, color: string),
                Rule(pattern: #"\b(?:def|class|import|from|return|if|elif|else|for|while|in|not|and|or|is|None|True|False|with|as|try|except|finally|raise|lambda|yield|pass|break|continue|global|nonlocal)\b"#, color: keyword),
                Rule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: number),
            ]
        case "bash", "sh", "shell", "zsh":
            return [
                Rule(pattern: #"#[^\n]*"#, color: comment),
                Rule(pattern: #""(?:[^"\\]|\\.)*"|'[^']*'"#, color: string),
                Rule(pattern: #"\b(?:if|then|else|elif|fi|for|in|do|done|while|case|esac|function|return|export|local|cd|echo)\b"#, color: keyword),
                Rule(pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, color: number),
            ]
        case "swift":
            return [
                Rule(pattern: #"//[^\n]*"#, color: comment),
                Rule(pattern: #""(?:[^"\\]|\\.)*""#, color: string),
                Rule(pattern: #"\b(?:let|var|func|struct|class|enum|protocol|extension|if|else|guard|for|in|while|return|import|private|public|internal|static|self|init|nil|true|false|throws|try|catch|async|await)\b"#, color: keyword),
                Rule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: number),
            ]
        case "javascript", "js", "typescript", "ts", "tsx", "jsx":
            return [
                Rule(pattern: #"//[^\n]*"#, color: comment),
                Rule(pattern: #"/\*[\s\S]*?\*/"#, color: comment),
                Rule(pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#, color: string),
                Rule(pattern: #"\b(?:const|let|var|function|return|if|else|for|while|switch|case|break|continue|new|class|extends|import|from|export|default|async|await|try|catch|finally|throw|typeof|instanceof|null|undefined|true|false|this)\b"#, color: keyword),
                Rule(pattern: #"\b\d+(?:\.\d+)?\b"#, color: number),
            ]
        default:
            return []
        }
    }
}
