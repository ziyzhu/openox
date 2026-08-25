#if targetEnvironment(simulator)
import Foundation

enum DebugUIAPI {
    typealias IDRequest = OxHostAPI.IDRequest
    typealias PromptRequest = OxHostAPI.PromptRequest
    typealias StatusResult = OxHostAPI.StatusResult
    typealias ComposerFormattingResult = OxHostAPI.ComposerFormattingResult
    typealias GetTranscriptResult = OxHostAPI.GetTranscriptResult

    @MainActor weak static var viewportController: ChatViewportController?
    @MainActor weak static var composer: ChatComposerModel?
    @MainActor static var setEditDraft: ((String) -> Void)?

    static func encode<T: Encodable>(_ value: T) -> Data {
        OxHostAPI.encode(value)
    }

    @MainActor
    static func handleGetTranscript(
        _ command: IDRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let viewportController else {
            reply(encode(GetTranscriptResult(
                id: command.id,
                ok: false,
                transcript: nil,
                error: "transcript unavailable"
            )))
            return
        }
        reply(encode(GetTranscriptResult(
            id: command.id,
            ok: true,
            transcript: viewportController.debugSnapshot(),
            error: nil
        )))
    }
}
#endif
