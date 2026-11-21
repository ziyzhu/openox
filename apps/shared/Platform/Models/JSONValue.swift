import Foundation

nonisolated public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public func merging(_ fields: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in fields { o[k] = v }
        return .object(o)
    }

    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.toAny() }
            return out
        }
    }

    public static func from(_ any: Any) -> JSONValue {
        if let j = any as? JSONValue { return j }
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if let i = Int(exactly: n) { return .int(i) }
            return .double(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(JSONValue.from)) }
        if let o = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k] = .from(v) }
            return .object(out)
        }
        return .null
    }

    public func jsonString(fallback: String = "{}") -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string
    }

    @concurrent
    public static func decode(_ data: Data) async throws -> JSONValue {
        try JSONValueParser.parse(data)
    }

    @concurrent
    public func encoded() async throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func parse(jsonString: String) -> JSONValue? {
        guard let data = jsonString.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue.from(any)
    }
}

nonisolated private struct JSONValueParser {
    private static let maximumDepth = 512
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private var depth = 0

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var parser = JSONValueParser(bytes: raw.bindMemory(to: UInt8.self))
            parser.skipWhitespace()
            let value = try parser.value()
            parser.skipWhitespace()
            guard parser.index == parser.bytes.count else { throw parser.failure("Unexpected content after JSON value") }
            return value
        }
    }

    private func failure(_ message: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "\(message) at byte \(index)"))
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func value() throws -> JSONValue {
        switch current {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case nil: throw failure("Unexpected end of JSON")
        default: return try number()
        }
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard consume(byte) else { throw failure("Invalid literal") }
        }
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("JSON nesting is too deep") }
        index += 1
        skipWhitespace()
    }

    private mutating func object() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        var fields: [String: JSONValue] = [:]
        if consume(UInt8(ascii: "}")) { return .object(fields) }
        while true {
            guard current == UInt8(ascii: "\"") else { throw failure("Expected object key") }
            let key = try string()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw failure("Expected colon") }
            skipWhitespace()
            let value = try value()
            if fields[key] == nil { fields[key] = value }
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(fields) }
            guard consume(UInt8(ascii: ",")) else { throw failure("Expected comma or closing brace") }
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(fields) }
        }
    }

    private mutating func array() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        var values: [JSONValue] = []
        if consume(UInt8(ascii: "]")) { return .array(values) }
        while true {
            values.append(try value())
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(values) }
            guard consume(UInt8(ascii: ",")) else { throw failure("Expected comma or closing bracket") }
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(values) }
        }
    }

    private mutating func string() throws -> String {
        index += 1
        let start = index
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return text
            case UInt8(ascii: "\\"):
                return try escapedString(prefix: Array(bytes[start..<index]))
            case ..<0x20:
                throw failure("Unescaped control character in string")
            default:
                index += 1
            }
        }
        throw failure("Unterminated string")
    }

    private mutating func escapedString(prefix: [UInt8]) throws -> String {
        var utf8 = prefix
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escape = current else { throw failure("Unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"): utf8.append(contentsOf: try unicodeEscape())
                default: throw failure("Invalid escape")
                }
            case ..<0x20:
                throw failure("Unescaped control character in string")
            default:
                utf8.append(byte)
            }
        }
        throw failure("Unterminated string")
    }

    private mutating func unicodeEscape() throws -> String.UTF8View {
        var value = try hexQuad()
        switch value {
        case 0xD800...0xDBFF:
            guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else { throw failure("Unpaired surrogate") }
            let low = try hexQuad()
            guard (0xDC00...0xDFFF).contains(low) else { throw failure("Unpaired surrogate") }
            value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
        case 0xDC00...0xDFFF:
            throw failure("Unpaired surrogate")
        default:
            break
        }
        guard let scalar = Unicode.Scalar(value) else { throw failure("Invalid unicode escape") }
        return String(Character(scalar)).utf8
    }

    private mutating func hexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = Self.hexDigit(byte) else { throw failure("Invalid unicode escape") }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    private var atDigit: Bool { current.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? false }

    private mutating func digits() throws {
        guard atDigit else { throw failure("Invalid number") }
        while atDigit { index += 1 }
    }

    private mutating func number() throws -> JSONValue {
        let start = index
        _ = consume(UInt8(ascii: "-"))
        if consume(UInt8(ascii: "0")) {
            if atDigit { throw failure("Invalid number") }
        } else {
            try digits()
        }
        let integerEnd = index
        var fractionIsZero = true
        if consume(UInt8(ascii: ".")) {
            let fractionStart = index
            try digits()
            fractionIsZero = bytes[fractionStart..<index].allSatisfy { $0 == UInt8(ascii: "0") }
        }
        let hasFraction = integerEnd != index
        var hasExponent = false
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            hasExponent = true
            if !consume(UInt8(ascii: "+")) { _ = consume(UInt8(ascii: "-")) }
            try digits()
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        if !hasExponent, fractionIsZero {
            let integer = hasFraction ? String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<integerEnd]), as: UTF8.self) : text
            if let value = Int(integer) { return .int(value) }
        }
        guard let double = Double(text), double.isFinite else { throw failure("Number is out of range") }
        if hasFraction || hasExponent, let value = Int(exactly: double) { return .int(value) }
        return .double(double)
    }
}
