import Foundation
import CryptoKit
import Darwin

extension ConversationMigrator {
    static func decodeDurableConversation(metadata data: Data, transcript: Int32?, checkpoint contextData: Data?,
        sources: [String: JSONValue], scope: ProfileScope, names: Set<String>, store: DurableFileStore) throws -> JSONValue {
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        decoder.userInfo[.fileDirectoryListing] = FileDirectoryListing()
        let metadata = try decodeMigrationValue(ConversationMeta.self, from: data, decoder: decoder, path: "chat.json")
        guard metadata.schemaVersion == ConversationFormat.currentSchemaVersion, let metadataSource = sources["metadata"] else {
            throw StorageMigrationError.invalidApplicationStorage("conversation source schema")
        }
        Log.app.info("ConversationMigrator.start id=\(metadata.id) source=native")
        var payloads: [String: JSONValue] = [:]
        var records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)] = []
        if let transcript {
            let reader = DurableTranscriptReader(descriptor: transcript, store: store)
            while let record = try reader.next() {
                var missingPurposes: Set<UUID> = []
                let value = mapMigrationInvocations(in: record.value) { invocation in
                    var invocation = invocation
                    if invocation["purpose"] == nil {
                        invocation["purpose"] = .string("")
                        if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)) { missingPurposes.insert(id) }
                    }
                    return invocation
                }
                let turn = try decodeMigrationValue(Turn.self, from: Data(value.jsonString().utf8), decoder: decoder,
                    path: "turns.jsonl:\(records.count + 1)")
                records.append((turn, record.source, missingPurposes))
                payloads[record.source.objectValue!["path"]!.stringValue!] = record.source
            }
            let missingPurposes = records.reduce(0) { $0 + $1.missingPurposes.count }
            Log.app.info("ConversationMigrator.transcript id=\(metadata.id) turns=\(records.count) externalized=\(reader.externalized) legacyPurposes=\(missingPurposes) bytes=\(reader.position)")
        }
        let turns = records.map(\.turn)
        var document = ConversationDocument(turns: turns)
        guard document.turns.map(\.id) == turns.map(\.id) else { throw StorageMigrationError.invalidApplicationStorage("conversation turn identities") }
        document.apply(.sealAllTurns)
        let checkpoint = try contextData.map {
            try decodeMigrationValue(AgentContextCheckpoint.self, from: $0, decoder: decoder, path: "context.json")
        }
        let original = try contextData.map { try decoder.decode(JSONValue.self, from: $0) }
        let boundary = try checkpoint.map {
            try durableCheckpointBoundary($0, records: records, originalMessages: original?.objectValue?["messages"], store: store)
        } ?? nil
        if checkpoint != nil, boundary == nil {
            Log.app.warning("ConversationMigrator.context id=\(metadata.id) reason=staleTranscriptCheckpoint source=completeTranscript")
        } else if turns.requiresContextCheckpoint, checkpoint == nil {
            Log.app.warning("ConversationMigrator.context id=\(metadata.id) reason=missingCheckpoint source=completeTranscript")
        }
        let alias = "ox-native:\(metadata.id.uuidString)"
        var unavailableAttachments = 0
        func messages(_ source: [Message]) -> [JSONValue] {
            source.map { message in
                var fields = DurableMessageCodec.message(message, provider: alias, profileID: scope.profileID).objectValue!
                fields["content"] = .array((fields["content"]?.arrayValue ?? []).map { block in
                    guard let name = block.objectValue?["oxAttachment"]?.stringValue,
                          !names.contains(name.lowercased()) else { return block }
                    unavailableAttachments += 1
                    return .object(["type": .string("text"), "text": .string("[Unavailable historical attachment: artifacts/\(name)]")])
                })
                return .object(fields)
            }
        }
        var entries: [[String: Any]] = [["kind": "ox.native.metadata", "data": ["source": metadataSource.toAny()]]]
        if checkpoint != nil, boundary == nil, let source = sources["checkpoint"] {
            entries.append(["kind": "ox.native.context", "data": ["source": source.toAny()]])
        }
        var expected: [Any] = []
        for (index, turn) in document.turns.enumerated() {
            let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn))
            let model = messages(ConversationProjection.makeWireMessages(from: [turn])).map { $0.toAny() }
            expected.append(contentsOf: model)
            entries.append(["kind": "ox.native.turn", "model": model, "data": ["turn": canonical, "source": records[index].source.toAny()]])
            if index == boundary, let checkpoint, let source = sources["checkpoint"] {
                expected = messages(checkpoint.messages).map { $0.toAny() }
                entries.append(["kind": "pi.reset", "head": "self", "data": ["source": source.toAny()], "model": expected])
            }
        }
        if unavailableAttachments > 0 {
            Log.app.warning("ConversationMigrator.attachments id=\(metadata.id) unavailable=\(unavailableAttachments) sourcePreserved=true")
        }
        return .from(["entries": entries, "expectedContext": try durableExpectedContext(expected), "payloads": payloads.values.map { $0.toAny() }])
    }
}

extension ConversationMigrator {
    static func decodeMigrationValue<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder, path: String) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            let reason: String
            switch error {
            case .keyNotFound(let key, let detail): context = detail; reason = "missingKey:\(key.stringValue)"
            case .valueNotFound(_, let detail): context = detail; reason = "missingValue"
            case .typeMismatch(_, let detail): context = detail; reason = "typeMismatch"
            case .dataCorrupted(let detail): context = detail; reason = "dataCorrupted"
            @unknown default: throw error
            }
            let field = String(context.codingPath.map(\.stringValue).joined(separator: ".").prefix(512))
            Log.app.error("StorageMigrator.pi decode failed path=\(path) field=\(field) reason=\(reason) sourcePreserved=true")
            throw error
        }
    }

    static func mapMigrationInvocations(in value: JSONValue, transform: ([String: JSONValue]) -> [String: JSONValue]) -> JSONValue {
        guard var root = value.objectValue, root["type"] == .string("agent"),
              var agent = root["agent"]?.objectValue, let steps = agent["steps"]?.arrayValue else { return value }
        agent["steps"] = .array(steps.map { value in
            guard var step = value.objectValue, step["type"] == .string("action"),
                  var action = step["action"]?.objectValue, action["type"] == .string("execute"),
                  var execution = action["execute"]?.objectValue, let effects = execution["effects"]?.arrayValue else { return value }
            execution["effects"] = .array(effects.compactMap { value in
                guard var effect = value.objectValue else { return value }
                if ["step", "widget", "media"].contains(effect["type"]?.stringValue ?? ""),
                   let fields = value.toAny() as? [String: Any] {
                    guard let legacy = ConversationMigrator.canonicalLegacyEffect(fields) else { return nil }
                    effect = JSONValue.from(legacy).objectValue!
                }
                if effect["type"] == .string("invocation"), let invocation = effect["invocation"]?.objectValue {
                    effect["invocation"] = .object(transform(invocation))
                }
                return .object(effect)
            })
            action["execute"] = .object(execution)
            step["action"] = .object(action)
            return .object(step)
        })
        root["agent"] = .object(agent)
        return .object(root)
    }

    static func durableCheckpointBoundary(_ checkpoint: AgentContextCheckpoint,
        records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)], originalMessages: JSONValue?, store: DurableFileStore) throws -> Int? {
        let turns = records.map(\.turn)
        if let boundary = checkpoint.boundary(in: turns) { return boundary }
        guard checkpoint.schemaVersion == AgentContextCheckpoint.currentSchemaVersion,
              let boundary = turns.firstIndex(where: { $0.id == checkpoint.throughTurnID }) else {
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint boundary")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let currentMessagesDigest = durableDigest(try encoder.encode(checkpoint.messages))
        let originalMessagesDigest = try originalMessages.map { durableDigest(try encoder.encode($0)) }
        guard currentMessagesDigest == checkpoint.messagesDigest || originalMessagesDigest == checkpoint.messagesDigest else {
            Log.app.error("StorageMigrator.pi checkpoint invalid component=messages turn=\(checkpoint.throughTurnID.rawValue)")
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint messages")
        }
        var hash = SHA256()
        func append(_ value: JSONValue) throws {
            if let fields = value.objectValue, let reference = fields["oxPayload"]?.objectValue, reference["format"] == .int(1),
               let source = reference["source"], let offset = reference["offset"]?.intValue, let length = reference["length"]?.intValue {
                let original = try store.capturePayload(source, offset: offset, length: length)
                let decoded = try JSONDecoder().decode(JSONValue.self, from: original)
                hash.update(data: try encoder.encode(decoded))
                return
            }
            switch value {
            case .array(let values):
                hash.update(data: Data("[".utf8))
                for (index, item) in values.enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    try append(item)
                }
                hash.update(data: Data("]".utf8))
            case .object(let fields):
                hash.update(data: Data("{".utf8))
                for (index, key) in fields.keys.sorted().enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    hash.update(data: try encoder.encode(key))
                    hash.update(data: Data(":".utf8))
                    try append(fields[key]!)
                }
                hash.update(data: Data("}".utf8))
            default: hash.update(data: try encoder.encode(value))
            }
        }
        hash.update(data: Data("[".utf8))
        for (index, record) in records[...boundary].enumerated() {
            if index > 0 { hash.update(data: Data(",".utf8)) }
            let canonical = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(record.turn))
            let original = mapMigrationInvocations(in: canonical) { invocation in
                var invocation = invocation
                if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)), record.missingPurposes.contains(id) {
                    invocation.removeValue(forKey: "purpose")
                }
                return invocation
            }
            try append(original)
        }
        hash.update(data: Data("]".utf8))
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == checkpoint.transcriptPrefixDigest else {
            Log.app.warning("StorageMigrator.pi checkpoint stale component=transcript turn=\(checkpoint.throughTurnID.rawValue)")
            return nil
        }
        return boundary
    }

    static func durableExpectedContext(_ source: [Any]) throws -> [[String: Any]] {
        let messages = try source.map { value -> [String: Any] in
            guard let message = value as? [String: Any] else { throw StorageMigrationError.invalidApplicationStorage("model context") }
            return message
        }.filter { $0["role"] as? String != "assistant" || !["aborted", "error", "deferred"].contains($0["stopReason"] as? String ?? "") }
        var ordered: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            if message["role"] as? String == "toolResult" { continue }
            ordered.append(message)
            guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { continue }
            var results: [String: [String: Any]] = [:]
            for candidate in messages.dropFirst(index + 1) {
                if candidate["role"] as? String == "assistant" { break }
                if candidate["role"] as? String == "toolResult", let id = candidate["toolCallId"] as? String, results[id] == nil { results[id] = candidate }
            }
            for call in content where call["type"] as? String == "toolCall" {
                guard let id = call["id"] as? String, let name = call["name"] as? String, let timestamp = message["timestamp"] else {
                    throw StorageMigrationError.invalidApplicationStorage("tool context")
                }
                ordered.append(results[id] ?? ["role": "toolResult", "toolCallId": id, "toolName": name,
                    "content": [["type": "text", "text": "Tool result unavailable: history ends before this call completed."]],
                    "isError": true, "details": ["reason": "missing_result"], "timestamp": timestamp])
            }
        }
        return ordered
    }

    final class DurableTranscriptReader {
        private let descriptor: Int32
        private let store: DurableFileStore
        private var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        private var count = 0
        private var index = 0
        private var archived = 0
        private var writer: DurablePayloadWriter?
        private var recordStart = 0
        private var captures: [[String]: (offset: Int, length: Int)] = [:]
        private(set) var position = 0
        private(set) var externalized = 0

        init(descriptor: Int32, store: DurableFileStore) {
            self.descriptor = descriptor
            self.store = store
        }

        func next() throws -> (value: JSONValue, source: JSONValue)? {
            while let byte = try peek(), byte == 10 || byte == 13 { advance() }
            guard try peek() != nil else { return nil }
            recordStart = position
            captures.removeAll(keepingCapacity: true)
            writer = try store.payloadWriter()
            archived = index
            let value = try parse(path: [], build: true, depth: 0)
            try spaces()
            guard let value, try peek() == nil || peek() == 10 else { throw invalid() }
            try flush()
            let source = try writer!.finish()
            writer = nil
            return (bind(value, source: source), source)
        }

        private func bind(_ value: JSONValue, path: [String] = [], source: JSONValue) -> JSONValue {
            if let capture = captures[path] {
                return .object([
                    "oxPayload": .object(["format": .int(1), "source": source, "offset": .int(capture.offset), "length": .int(capture.length)]),
                    "preview": .string("Large historical value omitted from model context."),
                ])
            }
            switch value {
            case .array(let values): return .array(values.enumerated().map { bind($0.element, path: path + [String($0.offset)], source: source) })
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, bind($0.value, path: path + [$0.key], source: source)) }))
            default: return value
            }
        }

        private func parse(path: [String], build: Bool, depth: Int) throws -> JSONValue? {
            guard depth <= 128 else { throw invalid() }
            try spaces()
            if build, path.suffix(4) == ["invocation", "outcome", "succeeded", "_0"] || path.suffix(2) == ["invocation", "args"] {
                let start = position - recordStart
                _ = try parse(path: path, build: false, depth: depth)
                let length = position - recordStart - start
                try flush()
                if length <= DurablePayloadWriter.inlineLimit {
                    return try JSONDecoder().decode(JSONValue.self, from: writer!.read(offset: start, length: length))
                }
                externalized += 1
                captures[path] = (start, length)
                return .null
            }
            guard let byte = try peek() else { throw invalid() }
            if byte == 123 {
                advance()
                var fields: [String: JSONValue] = [:]
                var keys = Set<String>()
                try spaces()
                if try peek() == 125 { advance(); return build ? .object(fields) : nil }
                while true {
                    guard try peek() == 34 else { throw invalid() }
                    let data = try string(collect: true)
                    let key = try JSONDecoder().decode(String.self, from: data!)
                    guard keys.insert(key).inserted else { throw invalid() }
                    try spaces()
                    try expect(58)
                    let value = try parse(path: build ? path + [key] : [], build: build, depth: depth + 1)
                    if let value { fields[key] = value }
                    try spaces()
                    if try peek() == 125 { advance(); break }
                    try expect(44)
                    try spaces()
                }
                return build ? .object(fields) : nil
            }
            if byte == 91 {
                advance()
                var values: [JSONValue] = []
                var ordinal = 0
                try spaces()
                if try peek() == 93 { advance(); return build ? .array(values) : nil }
                while true {
                    if let value = try parse(path: build ? path + [String(ordinal)] : [], build: build, depth: depth + 1) { values.append(value) }
                    ordinal += 1
                    try spaces()
                    if try peek() == 93 { advance(); break }
                    try expect(44)
                }
                return build ? .array(values) : nil
            }
            if byte == 34 {
                let data = try string(collect: build)
                return try data.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
            }
            var token = Data()
            while let byte = try peek(), ![9, 10, 13, 32, 44, 93, 125].contains(byte) {
                guard token.count < 1024 else { throw invalid() }
                token.append(byte)
                advance()
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: token)
            return build ? value : nil
        }

        private func string(collect: Bool) throws -> Data? {
            try expect(34)
            var token: Data? = collect ? Data([34]) : nil
            var remaining = 0
            var lower: UInt8 = 0x80
            var upper: UInt8 = 0xbf
            while true {
                guard try peek() != nil else { throw invalid() }
                let start = index
                while index < count {
                    let byte = buffer[index]
                    if byte == 34 || byte == 92 || byte < 32 { break }
                    if remaining > 0 {
                        guard byte >= lower, byte <= upper else { throw invalid() }
                        remaining -= 1
                        lower = 0x80; upper = 0xbf
                    } else if byte >= 0x80 {
                        switch byte {
                        case 0xc2...0xdf: remaining = 1
                        case 0xe0: remaining = 2; lower = 0xa0
                        case 0xe1...0xec, 0xee...0xef: remaining = 2
                        case 0xed: remaining = 2; upper = 0x9f
                        case 0xf0: remaining = 3; lower = 0x90
                        case 0xf1...0xf3: remaining = 3
                        case 0xf4: remaining = 3; upper = 0x8f
                        default: throw invalid()
                        }
                    }
                    index += 1; position += 1
                }
                if collect {
                    token!.append(contentsOf: buffer[start..<index])
                    guard token!.count <= 64 * 1024 * 1024 else { throw invalid() }
                }
                guard let byte = try peek() else { throw invalid() }
                if byte == 34 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(34)
                    return token
                }
                if byte == 92 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(92)
                    guard let escape = try peek(), [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escape) else { throw invalid() }
                    advance()
                    token?.append(escape)
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let hex = try peek(), (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw invalid() }
                            advance()
                            token?.append(hex)
                        }
                    }
                } else if byte < 32 { throw invalid() }
            }
        }

        private func spaces() throws {
            while let byte = try peek(), [9, 13, 32].contains(byte) { advance() }
        }

        private func expect(_ byte: UInt8) throws {
            guard try peek() == byte else { throw invalid() }
            advance()
        }

        private func advance() { index += 1; position += 1 }

        private func peek() throws -> UInt8? {
            if index == count {
                try flush()
                repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw invalid() }
                index = 0; archived = 0
            }
            return index < count ? buffer[index] : nil
        }

        private func flush() throws {
            if let writer, archived < index { try writer.append(Data(buffer[archived..<index])) }
            archived = index
        }

        private func invalid() -> StorageMigrationError { .invalidApplicationStorage("chat transcript near byte \(position)") }
    }

    static func durableDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
