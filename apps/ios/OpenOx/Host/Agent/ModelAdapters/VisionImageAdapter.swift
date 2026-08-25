import CryptoKit
import Foundation
import ImageIO
import Vision

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
            guard let message = await transform(message) else { return .failed }
            transformed.append(message)
        }
        return .transformed(transformed)
    }

    private func transform(_ message: Message) async -> Message? {
        switch message {
        case .user(var user):
            var content: [ContentBlock] = []
            var transformed = false
            for block in user.content {
                guard case .attachment(let artifact) = block, artifact.kind == .image else {
                    content.append(block)
                    continue
                }
                guard let data = try? Data(contentsOf: artifact.fileURL),
                      let analysis = await analysis(data: data, filename: artifact.fileName, mimeType: artifact.mimeType) else {
                    Log.agent.error("VisionImageAdapter couldn't analyze artifact=\(artifact.fileName)")
                    return nil
                }
                content.append(.text(TextContent("\(ArtifactPromptReference.text(for: artifact))\n\n\(analysis)")))
                transformed = true
            }
            guard transformed else { return message }
            user.content = content
            return .user(user)

        case .toolResult(var result):
            var content: [ContentBlock] = []
            var transformed = false
            for block in result.content {
                guard case .attachment(let artifact) = block, artifact.kind == .image else {
                    content.append(block)
                    continue
                }
                guard let data = try? Data(contentsOf: artifact.fileURL),
                      let analysis = await analysis(data: data, filename: artifact.fileName, mimeType: artifact.mimeType) else {
                    Log.agent.error("VisionImageAdapter couldn't analyze tool artifact=\(artifact.fileName)")
                    return nil
                }
                content.append(.text(TextContent("\n\n\(ArtifactPromptReference.text(for: artifact))\n\n\(analysis)")))
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
                    return nil
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

        case .assistant:
            return message
        }
    }

    private func analysis(data: Data, filename: String, mimeType: String) async -> String? {
        guard let observation = await VisionImageAnalysisCache.shared.analyze(data) else { return nil }
        var value: [String: Any] = [
            "filename": filename,
            "mimeType": mimeType,
            "pixelWidth": observation.pixelWidth,
            "pixelHeight": observation.pixelHeight,
            "recognizedText": observation.recognizedText,
            "classifications": observation.classifications.map {
                ["label": $0.label, "confidence": rounded($0.confidence)]
            },
        ]
        if observation.recognizedTextTruncated { value["recognizedTextTruncated"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "<image-analysis provenance=\"apple-vision\">\n\(json)\n</image-analysis>"
    }

    private func rounded(_ value: Float) -> Double {
        (Double(value) * 1_000).rounded() / 1_000
    }
}

nonisolated private struct VisionImageObservation: Sendable {
    struct Classification: Sendable {
        let label: String
        let confidence: Float
    }

    let pixelWidth: Int
    let pixelHeight: Int
    let recognizedText: String
    let recognizedTextTruncated: Bool
    let classifications: [Classification]
}

private actor VisionImageAnalysisCache {
    enum Entry: Sendable {
        case observation(VisionImageObservation)
        case failed
    }

    static let shared = VisionImageAnalysisCache()
    private static let maximumEntries = 32
    private static let maximumRecognizedTextCharacters = 20_000
    private var entries: [Data: Entry] = [:]
    private var insertionOrder: [Data] = []

    func analyze(_ data: Data) async -> VisionImageObservation? {
        let digest = Data(SHA256.hash(data: data))
        if let entry = entries[digest] {
            Log.agent.info("VisionImageAdapter cache-hit bytes=\(data.count)")
            switch entry {
            case .observation(let observation): return observation
            case .failed: return nil
            }
        }
        let started = Date()
        guard let observation = await Self.analyzeUncached(data) else {
            insert(.failed, digest: digest)
            Log.agent.error("VisionImageAdapter analysis-failed bytes=\(data.count) ms=\(Int(Date().timeIntervalSince(started) * 1_000))")
            return nil
        }
        insert(.observation(observation), digest: digest)
        Log.agent.info("VisionImageAdapter analyzed bytes=\(data.count) size=\(observation.pixelWidth)x\(observation.pixelHeight) textChars=\(observation.recognizedText.count) labels=\(observation.classifications.count) ms=\(Int(Date().timeIntervalSince(started) * 1_000))")
        return observation
    }

    private func insert(_ entry: Entry, digest: Data) {
        entries[digest] = entry
        insertionOrder.append(digest)
        guard insertionOrder.count > Self.maximumEntries else { return }
        entries.removeValue(forKey: insertionOrder.removeFirst())
    }

    private static func analyzeUncached(_ data: Data) async -> VisionImageObservation? {
        let dimensions = imageDimensions(data)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        async let recognizedText = recognizeText(data)
        async let classifications = classify(data)
        let (text, labels) = await (recognizedText, classifications)
        let bounded = String(text.prefix(maximumRecognizedTextCharacters))
        return VisionImageObservation(
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            recognizedText: bounded,
            recognizedTextTruncated: bounded.count < text.count,
            classifications: labels
        )
    }

    private static func recognizeText(_ data: Data) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: data) else { return "" }
        return observations
            .map(\.transcript)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func classify(_ data: Data) async -> [VisionImageObservation.Classification] {
        let request = ClassifyImageRequest()
        guard let observations = try? await request.perform(on: data) else { return [] }
        return observations
            .filter { $0.confidence >= 0.15 }
            .prefix(12)
            .map { VisionImageObservation.Classification(label: $0.identifier, confidence: $0.confidence) }
    }

    private static func imageDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (width, height)
    }
}
