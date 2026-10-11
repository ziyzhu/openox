import CryptoKit
import Foundation
import ImageIO
import Vision

nonisolated struct OnDeviceVisionAnalysis: Sendable {
    struct Classification: Sendable {
        let label: String
        let confidence: Float
    }

    let pixelWidth: Int
    let pixelHeight: Int
    let recognizedText: String
    let recognizedTextTruncated: Bool
    let classifications: [Classification]

    func json(filename: String, mimeType: String) -> JSONValue {
        .object([
            "filename": .string(filename),
            "mimeType": .string(mimeType),
            "pixelWidth": .int(pixelWidth),
            "pixelHeight": .int(pixelHeight),
            "recognizedText": .string(recognizedText),
            "recognizedTextTruncated": .bool(recognizedTextTruncated),
            "classifications": .array(classifications.map {
                .object([
                    "label": .string($0.label),
                    "confidence": .double((Double($0.confidence) * 1_000).rounded() / 1_000),
                ])
            }),
        ])
    }

    func promptText(filename: String, mimeType: String) -> String? {
        let value = json(filename: filename, mimeType: mimeType).toAny()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "<image-analysis provenance=\"apple-vision\">\n\(json)\n</image-analysis>"
    }
}

actor OnDeviceVisionAnalyzer {
    enum Entry: Sendable {
        case analysis(OnDeviceVisionAnalysis)
        case failed
    }

    static let shared = OnDeviceVisionAnalyzer()
    private static let maximumEntries = 32
    private static let maximumRecognizedTextCharacters = 20_000
    private var entries: [Data: Entry] = [:]
    private var insertionOrder: [Data] = []

    func analyze(_ data: Data) async -> OnDeviceVisionAnalysis? {
        let digest = Data(SHA256.hash(data: data))
        if let entry = entries[digest] {
            Log.agent.info("OnDeviceVisionAnalyzer cache-hit bytes=\(data.count)")
            switch entry {
            case .analysis(let analysis): return analysis
            case .failed: return nil
            }
        }
        let started = Date()
        guard let analysis = await Self.analyzeUncached(data) else {
            insert(.failed, digest: digest)
            Log.agent.error("OnDeviceVisionAnalyzer analysis-failed bytes=\(data.count) ms=\(Int(Date().timeIntervalSince(started) * 1_000))")
            return nil
        }
        insert(.analysis(analysis), digest: digest)
        Log.agent.info("OnDeviceVisionAnalyzer analyzed bytes=\(data.count) size=\(analysis.pixelWidth)x\(analysis.pixelHeight) textChars=\(analysis.recognizedText.count) labels=\(analysis.classifications.count) ms=\(Int(Date().timeIntervalSince(started) * 1_000))")
        return analysis
    }

    private func insert(_ entry: Entry, digest: Data) {
        entries[digest] = entry
        insertionOrder.append(digest)
        guard insertionOrder.count > Self.maximumEntries else { return }
        entries.removeValue(forKey: insertionOrder.removeFirst())
    }

    private static func analyzeUncached(_ data: Data) async -> OnDeviceVisionAnalysis? {
        let dimensions = imageDimensions(data)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        async let recognizedText = recognizeText(data)
        async let classifications = classify(data)
        let (text, labels) = await (recognizedText, classifications)
        let bounded = String(text.prefix(maximumRecognizedTextCharacters))
        return OnDeviceVisionAnalysis(
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

    private static func classify(_ data: Data) async -> [OnDeviceVisionAnalysis.Classification] {
        let request = ClassifyImageRequest()
        guard let observations = try? await request.perform(on: data) else { return [] }
        return observations
            .filter { $0.confidence >= 0.15 }
            .prefix(12)
            .map { OnDeviceVisionAnalysis.Classification(label: $0.identifier, confidence: $0.confidence) }
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
