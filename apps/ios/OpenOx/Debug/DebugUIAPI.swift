#if targetEnvironment(simulator)
import Foundation

enum DebugUIAPI {
    typealias IDRequest = OxHostProtocol.IDRequest
    typealias PromptRequest = OxHostProtocol.PromptRequest
    typealias StatusResult = OxHostProtocol.StatusResult
    typealias ComposerFormattingResult = OxHostProtocol.ComposerFormattingResult

    @MainActor weak static var composer: ChatComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?

    static func encode<T: Encodable>(_ value: T) -> Data {
        OxHostProtocol.encode(value)
    }
}
#endif
