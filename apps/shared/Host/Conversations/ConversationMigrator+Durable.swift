import Foundation
import Darwin

extension ConversationMigrator {
    static func decodeDurableConversation(metadata data: Data, transcript: Int32?, checkpoint contextData: Data?,
        sources: [String: JSONValue], scope: ProfileScope, names: Set<String>, store: DurableFileStore) throws -> JSONValue {
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        decoder.userInfo[.artifactDirectoryListing] = FileDirectoryListing()
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
