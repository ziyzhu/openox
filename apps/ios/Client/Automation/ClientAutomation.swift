import Foundation

enum ClientAutomation {
    typealias EmptyRequest = ProfileProtocol.EmptyRequest
    typealias PromptRequest = ProfileProtocol.PromptRequest
    typealias ComposerFormattingResult = ProfileProtocol.ComposerFormattingResult

    @MainActor weak static var composer: ConversationComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?


}

extension ClientAutomation: RuntimeAutomation {
    static func perform(_ method: ProfileProtocol.Method, params: JSONValue, reply: ProfileRPC.Reply) throws {
        let data = try JSONEncoder().encode(params)
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == EmptyRequest.self && params != .object([:]) {
                throw RuntimeError.bridge("This method takes no parameters")
            }
            return try JSONDecoder().decode(type, from: data)
        }
        switch method {
        case .getComposerFormatting: handleGetComposerFormatting(try decode(EmptyRequest.self), reply: reply)
        case .setComposerDraft: handleSetComposerDraft(try decode(PromptRequest.self), reply: reply)
        case .setComposerMarkedText: handleSetComposerMarkedText(try decode(PromptRequest.self), reply: reply)
        case .setPasteboardImage: handleSetPasteboardImage(try decode(EmptyRequest.self), reply: reply)
        case .setPasteboardRichText: handleSetPasteboardRichText(try decode(PromptRequest.self), reply: reply)
        case .stageSharedNote: handleStageSharedNote(try decode(PromptRequest.self), reply: reply)
        case .setEditDraft: handleSetEditDraft(try decode(PromptRequest.self), reply: reply)
        default: reply.failure("Method not found", code: -32601)
        }
    }
}
