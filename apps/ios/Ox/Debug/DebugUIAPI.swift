#if targetEnvironment(simulator)
import Foundation

enum DebugUIAPI {
    typealias EmptyRequest = OxHostProtocol.EmptyRequest
    typealias PromptRequest = OxHostProtocol.PromptRequest
    typealias ComposerFormattingResult = OxHostProtocol.ComposerFormattingResult

    @MainActor weak static var composer: ChatComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?


}
#endif
