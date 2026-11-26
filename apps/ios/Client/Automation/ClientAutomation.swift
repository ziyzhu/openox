import Foundation

enum ClientAutomation {
    typealias EmptyRequest = ProfileProtocol.EmptyRequest
    typealias PromptRequest = ProfileProtocol.PromptRequest
    typealias ComposerFormattingResult = ProfileProtocol.ComposerFormattingResult

    @MainActor weak static var composer: ConversationComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?


}
