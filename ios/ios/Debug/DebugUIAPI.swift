#if targetEnvironment(simulator)
import Foundation

enum DebugUIAPI {
    typealias IDRequest = OxHostAPI.IDRequest
    typealias PromptRequest = OxHostAPI.PromptRequest
    typealias StatusResult = OxHostAPI.StatusResult
    typealias ComposerFormattingResult = OxHostAPI.ComposerFormattingResult

    @MainActor weak static var composer: ChatComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?

    static func encode<T: Encodable>(_ value: T) -> Data {
        OxHostAPI.encode(value)
    }
}
#endif
