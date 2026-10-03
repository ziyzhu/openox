import Foundation

/// Registrable-domain lookup using the bundled ICANN and PRIVATE PSL rules.
/// Callers supply lowercase, IDNA-encoded hostnames, as with the former package.
nonisolated struct WebsitePublicSuffixList: Sendable {
    static let bundled: Self = {
        guard let bundle = Bundle.main.url(forResource: "PublicSuffixList", withExtension: "bundle"),
              let text = try? String(contentsOf: bundle.appendingPathComponent("public_suffix_list.dat"), encoding: .utf8)
        else { preconditionFailure("Could not load bundled Public Suffix List") }
        return Self(text: text)
    }()

    private let rules: Set<String>

    init(text: String) {
        rules = Set(text.components(separatedBy: .newlines).compactMap { line in
            let rule = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty else { return nil }
            // Foundation handles IDNA, so the Unicode source list needs no Punycode package.
            guard !rule.utf8.allSatisfy({ $0 < 128 }) else { return rule }
            let marker = rule.hasPrefix("*.") ? "*." : (rule.hasPrefix("!") ? "!" : "")
            guard let host = URL(string: "https://" + rule.dropFirst(marker.count))?.host else {
                preconditionFailure("Invalid internationalized Public Suffix List rule")
            }
            return marker + host
        })
    }

    func effectiveTLDPlusOne(_ hostname: String) -> String? {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        var suffixCount = 1 // The implicit '*' rule covers unknown suffixes.
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            // An exception removes its leftmost label from the public suffix,
            // making the exception itself the registrable domain.
            if rules.contains("!" + suffix) { return suffix }
            let wildcard = "*." + labels.dropFirst(index + 1).joined(separator: ".")
            if rules.contains(suffix) || rules.contains(wildcard) {
                suffixCount = max(suffixCount, labels.count - index)
            }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
