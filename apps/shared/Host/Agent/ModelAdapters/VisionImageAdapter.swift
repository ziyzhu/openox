import Foundation

nonisolated struct VisionImageAdapter: ModelAdapter {
    let id = "apple-vision-image"

    func transform(messages: [Message], model: ProviderModel) async -> ModelAdapterOutcome {
        guard !model.modalities.input.contains(.image),
              requiredInputModalities(in: messages).contains(.image) else {
            return .unchanged
        }

        var transformed: [Message] = []
        transformed.reserveCapacity(messages.count)
        for message in messages {
            transformed.append(await transform(message))
        }
        return .transformed(transformed)
    }

    private func transform(_ message: Message) async -> Message {
        switch message {
        case .user(var user):
            var content: [ContentBlock] = []
            var transformed = false
            for block in user.content {
                guard case .attachment(let file) = block, file.kind == .image else {
                    content.append(block)
                    continue
                }
                guard let data = try? ProviderFileInputs.read(file),
                      let analysis = await analysis(data: data, filename: file.fileName, mimeType: file.mimeType) else {
                    Log.agent.error("VisionImageAdapter couldn't analyze file=\(file.fileName)")
                    content.append(.text(TextContent(FileReferenceAdapter.recovery(kind: .image, source: FilePromptReference.text(for: file)))))
                    transformed = true
                    continue
                }
                content.append(.text(TextContent("\(FilePromptReference.text(for: file))\n\n\(analysis)")))
                transformed = true
            }
            guard transformed else { return message }
            user.content = content
            return .user(user)

        case .toolResult(var result):
            var content: [ContentBlock] = []
            var transformed = false
            for block in result.content {
                guard case .attachment(let file) = block, file.kind == .image else {
                    content.append(block)
                    continue
                }
                guard let data = try? ProviderFileInputs.read(file),
                      let analysis = await analysis(data: data, filename: file.fileName, mimeType: file.mimeType) else {
                    Log.agent.error("VisionImageAdapter couldn't analyze tool file=\(file.fileName)")
                    content.append(.text(TextContent(FileReferenceAdapter.recovery(kind: .image, source: FilePromptReference.text(for: file)))))
                    transformed = true
                    continue
                }
                content.append(.text(TextContent("\n\n\(FilePromptReference.text(for: file))\n\n\(analysis)")))
                transformed = true
            }

            var transient: [TransientAttachment] = []
            var transientAnalyses: [String] = []
            for attachment in result.transientAttachments {
                guard attachment.kind == .image else {
                    transient.append(attachment)
                    continue
                }
                guard let analysis = await analysis(
                    data: attachment.data,
                    filename: attachment.displayName,
                    mimeType: attachment.mimeType
                ) else {
                    Log.agent.error("VisionImageAdapter couldn't analyze transient=\(attachment.displayName)")
                    transientAnalyses.append(FileReferenceAdapter.recovery(kind: .image, source: FileReferenceAdapter.source(for: attachment)))
                    transformed = true
                    continue
                }
                transientAnalyses.append(analysis)
                transformed = true
            }
            guard transformed else { return message }
            if !transientAnalyses.isEmpty {
                content.append(.text(TextContent("\n\n\(transientAnalyses.joined(separator: "\n\n"))")))
            }
            result.content = content
            result.transientAttachments = transient
            return .toolResult(result)

        case .system, .assistant:
            return message
        }
    }

    private func analysis(data: Data, filename: String, mimeType: String) async -> String? {
        await OnDeviceVisionAnalyzer.shared.analyze(data)?.promptText(filename: filename, mimeType: mimeType)
    }
}
