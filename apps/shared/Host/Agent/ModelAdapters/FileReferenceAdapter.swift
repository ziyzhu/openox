import Foundation

nonisolated struct FileReferenceAdapter: ModelAdapter {
    let id = "lazy-file-reference"
    var loadsFilesLazily = true
    var wireProtocol: LLMWireProtocol?

    func transform(messages: [Message], model: ProviderModel) async -> ModelAdapterOutcome {
        var transformedMessages: [Message] = []
        var changed = false
        transformedMessages.reserveCapacity(messages.count)
        for message in messages {
            let transformed = transform(message, model: model)
            transformedMessages.append(transformed.message)
            changed = changed || transformed.changed
        }
        return changed ? .transformed(transformedMessages) : .unchanged
    }

    private func transform(_ message: Message, model: ProviderModel) -> (message: Message, changed: Bool) {
        switch message {
        case .user(var user):
            let transformed = transform(user.content, model: model)
            user.content = transformed.content
            return (.user(user), transformed.changed)
        case .toolResult(var result):
            let transformed = transform(result.content, model: model)
            result.content = transformed.content
            var changed = transformed.changed
            result.transientAttachments = result.transientAttachments.filter { attachment in
                let source = Self.source(for: attachment)
                if attachment.kind == .text, let text = String(data: attachment.data, encoding: .utf8) {
                    result.content.append(.text(TextContent("\(source)\nAttached UTF-8 text:\n\(text)")))
                } else {
                    guard attachment.kind == .text || needsRecovery(kind: attachment.kind, mimeType: attachment.mimeType, model: model) else { return true }
                    Log.agent.info("FileReferenceAdapter omitted kind=\(String(describing: attachment.kind)) mimeType=\(attachment.mimeType) model=\(model.id)")
                    result.content.append(.text(TextContent(Self.recovery(kind: attachment.kind, source: source))))
                }
                changed = true
                return false
            }
            return (.toolResult(result), changed)
        case .assistant:
            return (message, false)
        }
    }

    private func transform(_ content: [ContentBlock], model: ProviderModel) -> (content: [ContentBlock], changed: Bool) {
        var changed = false
        let transformed = content.map { block in
            guard case .attachment(let file) = block else { return block }
            let kind: TransientAttachment.Kind
            switch file.kind {
            case .image: kind = .image
            case .pdf: kind = .pdf
            case .text, .html: kind = .text
            case .file: kind = .file
            }
            let unsupported = needsRecovery(kind: kind, mimeType: file.mimeType, model: model)
            guard loadsFilesLazily || unsupported else { return block }
            changed = true
            if unsupported {
                Log.agent.info("FileReferenceAdapter omitted kind=\(String(describing: kind)) mimeType=\(file.mimeType) model=\(model.id)")
            }
            let source = FilePromptReference.text(for: file)
            return .text(TextContent(unsupported ? Self.recovery(kind: kind, source: source) : source))
        }
        return (transformed, changed)
    }

    private func needsRecovery(kind: TransientAttachment.Kind, mimeType: String, model: ProviderModel) -> Bool {
        switch kind {
        case .image: false
        case .pdf: !model.modalities.input.contains(.pdf)
        case .text: false
        case .file:
            !supportsMedia(mimeType: mimeType, model: model)
        }
    }

    private func supportsMedia(mimeType: String, model: ProviderModel) -> Bool {
        guard wireProtocol == .geminiGenerateContent else { return false }
        let mimeType = (mimeType.lowercased().split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        switch mimeType {
        case "audio/wav", "audio/mp3", "audio/aiff", "audio/aac", "audio/ogg", "audio/flac", "audio/mpeg", "audio/m4a":
            return model.modalities.input.contains(.audio)
        case "video/mp4", "video/mpeg", "video/mov", "video/avi", "video/x-flv", "video/mpg", "video/webm", "video/wmv", "video/3gpp":
            return model.modalities.input.contains(.video)
        default: return false
        }
    }

    static func source(for attachment: TransientAttachment) -> String {
        attachment.reference.map { "Available file reference: \($0.debugDescription)." }
            ?? "Source attachment: \(attachment.displayName.debugDescription). Use the source path or URL from the tool call."
    }

    static func recovery(kind: TransientAttachment.Kind, source: String) -> String {
        let guidance: String
        switch kind {
        case .pdf:
            guidance = "PDF input is unavailable for this model. Use ox.fs.read with the file reference/path to extract text, or ox.web.fetch for the source URL. Text extraction may omit diagrams or return no text for scanned pages."
        case .image:
            guidance = "Image input is unavailable for this model and local OCR/classification failed."
        case .text:
            guidance = "The text attachment is not valid UTF-8. Use ox.fs.read with the file reference/path or ox.web.fetch for the source URL; if decoding fails, request a UTF-8 export."
        case .file:
            guidance = "Native input support for this binary format is unavailable or unverified for this model and transport. ox.fs.read cannot decode this binary format. Use an attached service only if it supports extracting this format; otherwise explain the limitation and request a text, image, or PDF export, or a compatible model/provider."
        }
        return "Attachment omitted from this model request. Its contents are not included. \(source) \(guidance) Do not repeat ox.fs.attach for the same unsupported file. Use only available tools; if extraction is unavailable, explain the limitation instead of claiming to have read the file."
    }
}
