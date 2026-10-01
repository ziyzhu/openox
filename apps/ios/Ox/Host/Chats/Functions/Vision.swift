import Foundation

extension Chat {
    public func analyzeVision(filename: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["source": .string(filename)])
        return try await tracked(Actions.visionAnalyze, args, purpose: purpose) {
            let artifact = try await repository.artifact(named: filename, in: scope)
            guard artifact.exists else { throw ArtifactError.missing(filename) }
            guard artifact.kind == .image else {
                throw RuntimeError.bridge("ox.vision.analyze: artifact is not an image: \(artifact.fileName)")
            }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: artifact.fileURL)
            }.value
            guard let analysis = await OnDeviceVisionAnalyzer.shared.analyze(data) else {
                throw RuntimeError.bridge("ox.vision.analyze: image could not be analyzed: \(artifact.fileName)")
            }
            Log.session.info("bridge.vision.analyze filename=\(artifact.fileName) bytes=\(data.count) size=\(analysis.pixelWidth)x\(analysis.pixelHeight) textChars=\(analysis.recognizedText.count) labels=\(analysis.classifications.count)")
            return analysis
                .json(filename: artifact.fileName, mimeType: artifact.mimeType)
                .merging(["processing": .string("on-device")])
        }
    }
}
