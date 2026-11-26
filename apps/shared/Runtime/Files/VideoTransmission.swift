import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated struct TransmittedFile: Sendable {
    nonisolated enum Source: Sendable {
        case original
        case compressed(directory: URL)
    }

    let url: URL
    let name: String
    let source: Source

    func discard() {
        guard case .compressed(let directory) = source else { return }
        FileStaging.cleanup(directory, operation: "video-transmission")
    }
}

nonisolated enum VideoTransmission {
    static func prepare(_ url: URL, name: String) async -> TransmittedFile {
        let original = TransmittedFile(url: url, name: name, source: .original)
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { return original }
        let startedAt = ContinuousClock.now
        var directory: URL?
        do {
            let staging = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "video-transmission")
            directory = staging
            let output = staging.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".mp4")
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPreset1280x720) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try await session.export(to: output, as: .mp4)
            let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let after = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let durationMs = TurnLatencyTrace.milliseconds(startedAt.duration(to: .now))
            guard after < before else {
                Log.session.info("VideoTransmission.original bytes=\(before) compressedBytes=\(after) durationMs=\(durationMs)")
                FileStaging.cleanup(staging, operation: "video-transmission")
                return original
            }
            Log.session.info("VideoTransmission.compressed bytes=\(before) compressedBytes=\(after) durationMs=\(durationMs)")
            return TransmittedFile(url: output, name: output.lastPathComponent, source: .compressed(directory: staging))
        } catch {
            Log.session.error("VideoTransmission.failed error=\(error.localizedDescription)")
            directory.map { FileStaging.cleanup($0, operation: "video-transmission") }
            return original
        }
    }

    static func modelInput(_ descriptor: JSONValue, reader: DurableRuntime, name: String) async -> (data: Data, name: String)? {
        guard UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)?.conforms(to: .movie) == true,
              let digest = descriptor.objectValue?["sha256"]?.stringValue, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        let cache = AppStoragePaths.caches.appendingPathComponent("ModelVideoInputs", isDirectory: true)
        let cached = cache.appendingPathComponent(digest + ".mp4")
        let outputName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".mp4"
        if let data = try? Data(contentsOf: cached), data.count <= FileLimits.fileBytes { return (data, outputName) }
        var staging: URL?
        do {
            let directory = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "model-video")
            staging = directory
            let source = directory.appendingPathComponent(name)
            try await reader.copyFile(descriptor, to: source)
            let transmitted = await prepare(source, name: name)
            defer { transmitted.discard() }
            guard case .compressed = transmitted.source,
                  try transmitted.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= FileLimits.fileBytes else {
                Log.session.info("VideoTransmission.modelInput tooLarge digest=\(digest.prefix(12))")
                FileStaging.cleanup(directory, operation: "model-video")
                return nil
            }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: transmitted.url, to: cached)
            FileStaging.cleanup(directory, operation: "model-video")
            return (try Data(contentsOf: cached), outputName)
        } catch {
            Log.session.error("VideoTransmission.modelInput failed error=\(error.localizedDescription)")
            staging.map { FileStaging.cleanup($0, operation: "model-video") }
            return nil
        }
    }
}
