import Foundation

extension Conversation {
    public func analyzeVision(filename: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["source": .string(filename)])
        return try await tracked(Actions.visionAnalyze, args, purpose: purpose) {
            let path = filename.contains("/") ? filename : "artifacts/\(filename)"
            let media = try await self.fileSystemMedia(path: path)
            guard media.kind == .image else {
                throw RuntimeError.bridge("ox.vision.analyze: file is not an image: \(path)")
            }
            _ = try ImagePreparer.inspect(media.data)
            guard let analysis = await OnDeviceVisionAnalyzer.shared.analyze(media.data) else {
                throw RuntimeError.bridge("ox.vision.analyze: image could not be analyzed: \(path)")
            }
            try Task.checkCancellation()
            Log.session.info("bridge.vision.analyze path=\(path) bytes=\(media.data.count) size=\(analysis.pixelWidth)x\(analysis.pixelHeight) textChars=\(analysis.recognizedText.count) labels=\(analysis.classifications.count)")
            return analysis
                .json(filename: media.filename, mimeType: media.mimeType)
                .merging(["processing": .string("on-device")])
        }
    }
}
