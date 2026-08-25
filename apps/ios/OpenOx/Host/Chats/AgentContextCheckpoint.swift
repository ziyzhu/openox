import CryptoKit
import Foundation

nonisolated struct AgentContextCheckpoint: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let throughTurnID: TurnID
    let transcriptPrefixDigest: String
    let messagesDigest: String
    let messages: [Message]
    let tokensBefore: Int
    let createdAt: Date

    init(messages: [Message], tokensBefore: Int, turns: [Turn], through index: Int) {
        schemaVersion = Self.currentSchemaVersion
        throughTurnID = turns[index].id
        transcriptPrefixDigest = Self.digest(Array(turns[...index]))
        messagesDigest = Self.digest(messages)
        self.messages = messages
        self.tokensBefore = tokensBefore
        createdAt = Date()
    }

    func boundary(in turns: [Turn]) -> Int? {
        guard schemaVersion == Self.currentSchemaVersion,
              let index = turns.firstIndex(where: { $0.id == throughTurnID }),
              transcriptPrefixDigest == Self.digest(Array(turns[...index])),
              messagesDigest == Self.digest(messages) else { return nil }
        return index
    }

    static func == (lhs: AgentContextCheckpoint, rhs: AgentContextCheckpoint) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.throughTurnID == rhs.throughTurnID
            && lhs.transcriptPrefixDigest == rhs.transcriptPrefixDigest
            && lhs.messagesDigest == rhs.messagesDigest
            && lhs.tokensBefore == rhs.tokensBefore
            && lhs.createdAt == rhs.createdAt
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
