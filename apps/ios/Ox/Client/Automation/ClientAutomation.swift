import Foundation

enum ClientAutomation {
    typealias EmptyRequest = OxHostProtocol.EmptyRequest
    typealias PromptRequest = OxHostProtocol.PromptRequest
    typealias ComposerFormattingResult = OxHostProtocol.ComposerFormattingResult

    @MainActor weak static var composer: ConversationComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?


}
