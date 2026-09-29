import Foundation

nonisolated enum MandarinNumberNormalizer {

    private static let digits: [Character] = [
        "零", "一", "二", "三", "四", "五", "六", "七", "八", "九",
    ]
    private static let groupUnits: [String] = ["", "万", "亿", "兆"]

    static func normalize(_ text: String) -> String {
        var s = text
        for (pattern, transform) in pipeline {
            s = apply(pattern: pattern, transform: transform, to: s)
        }
        return s
    }


    static func cardinal(_ n: Int64) -> String {
        if n == 0 { return "零" }
        if n < 0 { return "负" + cardinal(-n) }

        var groups: [Int] = []
        var x = n
        while x > 0 {
            groups.append(Int(x % 10000))
            x /= 10000
        }
        if groups.count > groupUnits.count {
            return digitString(String(n))
        }

        var result = ""
        var emitted = false
        for i in (0..<groups.count).reversed() {
            let g = groups[i]
            if g == 0 { continue }
            if emitted && g < 1000 {
                result += "零"
            }
            result += fourDigitChunk(g, isHighest: !emitted)
            result += groupUnits[i]
            emitted = true
        }
        return result
    }

    private static func fourDigitChunk(_ n: Int, isHighest: Bool) -> String {
        if n == 0 { return "" }
        var result = ""
        let q = n / 1000
        let h = (n / 100) % 10
        let t = (n / 10) % 10
        let u = n % 10
        var pendingZero = false

        if q > 0 {
            result.append(digits[q])
            result += "千"
        }
        if h > 0 {
            result.append(digits[h])
            result += "百"
        } else if q > 0 && (t > 0 || u > 0) {
            pendingZero = true
        }
        if t > 0 {
            if pendingZero {
                result += "零"
                pendingZero = false
            }
            if t == 1 && q == 0 && h == 0 && isHighest {
                result += "十"
            } else {
                result.append(digits[t])
                result += "十"
            }
        } else if (q > 0 || h > 0) && u > 0 {
            pendingZero = true
        }
        if u > 0 {
            if pendingZero {
                result += "零"
                pendingZero = false
            }
            result.append(digits[u])
        }
        return result
    }

    static func digitString(_ s: String) -> String {
        var out = ""
        for ch in s {
            if let v = ch.wholeNumberValue, (0..<10).contains(v) {
                out.append(digits[v])
            } else if ch == "-" {
                out += "负"
            } else if ch == "." {
                out += "点"
            }
        }
        return out
    }

    static func decimal(_ s: String) -> String {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        if parts.count == 1 {
            return Int64(intPart).map(cardinal) ?? digitString(intPart)
        }
        var fracPart = String(parts[1])
        while fracPart.count > 1 && fracPart.last == "0" {
            fracPart.removeLast()
        }
        let intStr = Int64(intPart).map(cardinal) ?? digitString(intPart)
        if fracPart.isEmpty || fracPart == "0" {
            return intStr
        }
        return intStr + "点" + digitString(fracPart)
    }


    private typealias Transform = ([String]) -> String

    private static func apply(
        pattern: String,
        transform: Transform,
        to text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            fatalError("MandarinNumberNormalizer: invalid regex \(pattern)")
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            let mr = m.range
            if mr.location > cursor {
                out += ns.substring(
                    with: NSRange(location: cursor, length: mr.location - cursor))
            }
            var groups: [String] = []
            groups.reserveCapacity(m.numberOfRanges)
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            cursor = mr.location + mr.length
        }
        if cursor < ns.length {
            out += ns.substring(
                with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func intToHanzi(_ s: String) -> String {
        Int64(s).map(cardinal) ?? s
    }

    private static var pipeline: [(String, Transform)] {
        [
            (
                #"(\d{4})年(\d{1,2})月(\d{1,2})[日号]"#,
                { g in
                    digitString(g[1]) + "年" + intToHanzi(g[2]) + "月" + intToHanzi(g[3]) + "日"
                }
            ),
            (
                #"(\d{4})年(\d{1,2})月"#,
                { g in
                    digitString(g[1]) + "年" + intToHanzi(g[2]) + "月"
                }
            ),
            (
                #"(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b"#,
                { g in
                    digitString(g[1]) + "年" + intToHanzi(g[2]) + "月" + intToHanzi(g[3]) + "日"
                }
            ),
            (#"(\d{4})年"#, { g in digitString(g[1]) + "年" }),
            (
                #"(\d{1,2}):(\d{2}):(\d{2})"#,
                { g in
                    intToHanzi(g[1]) + "点" + intToHanzi(g[2]) + "分" + intToHanzi(g[3]) + "秒"
                }
            ),
            (
                #"(\d{1,2}):(\d{2})"#,
                { g in
                    intToHanzi(g[1]) + "点" + intToHanzi(g[2]) + "分"
                }
            ),
            (#"[¥￥](\d+(?:\.\d+)?)"#, { g in decimal(g[1]) + "元" }),
            (#"\$(\d+(?:\.\d+)?)"#, { g in decimal(g[1]) + "美元" }),
            (#"€(\d+(?:\.\d+)?)"#, { g in decimal(g[1]) + "欧元" }),
            (#"£(\d+(?:\.\d+)?)"#, { g in decimal(g[1]) + "英镑" }),
            (#"(\d+(?:\.\d+)?)%"#, { g in "百分之" + decimal(g[1]) }),
            (#"(\d+)/(\d+)"#, { g in intToHanzi(g[2]) + "分之" + intToHanzi(g[1]) }),
            (#"\d+\.\d+"#, { g in decimal(g[0]) }),
            (#"\d+"#, { g in intToHanzi(g[0]) }),
        ]
    }
}
