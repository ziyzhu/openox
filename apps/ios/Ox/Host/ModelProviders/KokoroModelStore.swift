import CoreML
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class KokoroModelStore {
    static let shared = KokoroModelStore()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    nonisolated static let modelID = "kokoro-af-heart-v1"
    nonisolated static let expectedBytes: Int64 = 184_548_804
    nonisolated static let revision = "9183566f294ca3f31a63fd2767cf5848bfebfd50"

    private nonisolated static let packages = [
        "kokoro_duration_t128",
        "kokoro_f0ntrain_t280",
        "kokoro_decoder_pre_7s",
        "kokoro_decoder_har_post_7s",
    ]

    private nonisolated static let files: [ModelFile] = [
        .init("kokoro_duration_t128", "Data/com.apple.CoreML/model.mlmodel", 177_940, "e8a280462b565461b69b7e33c17bdcceb0257cd7727259f388cbdabb4f8a3388"),
        .init("kokoro_duration_t128", "Data/com.apple.CoreML/weights/weight.bin", 56_723_456, "cf9b31ce85b3900d2319b8cc670587b6c130472518673549f30eba8048371bc0"),
        .init("kokoro_duration_t128", "Manifest.json", 617, "72d8af0017ff9c5205e7465cb54bc81996875ad7696734766705d769b35c534a"),
        .init("kokoro_f0ntrain_t280", "Data/com.apple.CoreML/model.mlmodel", 97_807, "74ddc2ea2949bb70c9c8658f6ecca3fe9881b33d71d6c363b94cabd75161836e"),
        .init("kokoro_f0ntrain_t280", "Data/com.apple.CoreML/weights/weight.bin", 20_496_384, "09418fc680f6be3e105bb4783e8110777524fa8ed7673d264eb3f55d6fd9a219"),
        .init("kokoro_f0ntrain_t280", "Manifest.json", 617, "d3e43e360b4a8110483d9d4d18ede2cc8e498b60bee739a373f61bed1b96f57a"),
        .init("kokoro_decoder_pre_7s", "Data/com.apple.CoreML/model.mlmodel", 80_052, "745fd14612bb3489f08f4579e939beb31bc28326ec559b48c5ac56b8b934845c"),
        .init("kokoro_decoder_pre_7s", "Data/com.apple.CoreML/weights/weight.bin", 67_190_976, "9932a592f367dc61f3912430dbb79a7149c88c09b46e1ee2b57122aac1e05271"),
        .init("kokoro_decoder_pre_7s", "Manifest.json", 617, "1bbef4f52473ffe69f4a1d0ce2f6ab5d308f4bc0bba83304a39678c97b73ab82"),
        .init("kokoro_decoder_har_post_7s", "Data/com.apple.CoreML/model.mlmodel", 425_873, "30e2596079616c5f8e3611f1512667714c9a4b7db5295be021034ea2b081e3e4"),
        .init("kokoro_decoder_har_post_7s", "Data/com.apple.CoreML/weights/weight.bin", 39_353_848, "e4ada8b28c56a4acda6a88e7c6d076aa65a39051841597bc0c4c07a60afe5ac2"),
        .init("kokoro_decoder_har_post_7s", "Manifest.json", 617, "e9a771b12b1852e8be84bca7c349eb2b7870ced937398670a4a6dfe3021308fa"),
    ]

    private(set) var state: State = .notInstalled
    private var operation: Task<Void, Never>?

    private var installationURL: URL {
        AppStoragePaths.models.appendingPathComponent(Self.modelID, isDirectory: true)
    }

    var modelsDirectory: URL? {
        guard state == .ready else { return nil }
        return installationURL.appendingPathComponent("Models", isDirectory: true)
    }

    private init() {
        refresh()
    }

    func refresh() {
        guard operation == nil else { return }
        if let entries = try? FileManager.default.contentsOfDirectory(at: AppStoragePaths.models, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("kokoro-af-heart-") && entry.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let receiptURL = installationURL.appendingPathComponent("receipt.json")
        let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let models = installationURL.appendingPathComponent("Models", isDirectory: true)
        state = receipt?.revision == Self.revision
            && Self.packages.allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0 + ".mlmodelc").path) }
            ? .ready : .notInstalled
    }

    func download() {
        guard operation == nil, state != .ready else { return }
        state = .downloading(0)
        operation = Task {
            do {
                try await install()
            } catch {
                state = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
                Log.ui.error("KokoroModel.download failed error=\(error.localizedDescription)")
            }
            operation = nil
        }
    }

    private func install() async throws {
        try ensureCapacity()
        let root = AppStoragePaths.models
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AppStoragePaths.excludeFromBackup(root)
        let stage = root.appendingPathComponent("kokoro-af-heart-" + UUID().uuidString + ".partial", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let sources = stage.appendingPathComponent("Sources", isDirectory: true)
        let models = stage.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        var completedBytes: Int64 = 0
        for file in Self.files {
            try Task.checkCancellation()
            let destination = sources.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/mattmireles/kokoro-coreml/resolve/\(Self.revision)/coreml/\(file.path)?download=true")!
            let priorBytes = completedBytes
            let progress = KokoroDownloadProgress { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(Double(priorBytes + Int64(Double(file.bytes) * fraction)) / Double(Self.expectedBytes))
                }
            }
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: progress)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw StoreError.invalidDownload
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try await Task.detached { try Self.verify(destination, file: file) }.value
            completedBytes += file.bytes
            state = .downloading(Double(completedBytes) / Double(Self.expectedBytes))
        }

        state = .preparing
        for name in Self.packages {
            try Task.checkCancellation()
            let input = sources.appendingPathComponent(name + ".mlpackage", isDirectory: true)
            let destination = models.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
            try await Task.detached {
                let compiled = try MLModel.compileModel(at: input)
                try FileManager.default.moveItem(at: compiled, to: destination)
            }.value
        }
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: sources)
        let receipt = Receipt(revision: Self.revision)
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        await KokoroTTS.shared.unload()
        if FileManager.default.fileExists(atPath: installationURL.path) {
            try FileManager.default.removeItem(at: installationURL)
        }
        try FileManager.default.moveItem(at: stage, to: installationURL)
        state = .ready
        Log.ui.info("KokoroModel.install model=\(Self.modelID) bytes=\(Self.expectedBytes)")
    }

    private func ensureCapacity() throws {
        let available = try AppStoragePaths.applicationSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let available, available < Self.expectedBytes * 3 + 268_435_456 {
            throw StoreError.insufficientSpace
        }
    }

    private nonisolated static func verify(_ url: URL, file: ModelFile) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == file.bytes else { throw StoreError.invalidModel }
        guard let stream = InputStream(url: url) else { throw StoreError.invalidModel }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let count = stream.read(buffer, maxLength: 1_048_576)
            if count < 0 { throw stream.streamError ?? StoreError.invalidModel }
            if count == 0 { break }
            hasher.update(data: Data(bytesNoCopy: buffer, count: count, deallocator: .none))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw StoreError.invalidModel }
    }

    private nonisolated struct ModelFile: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String

        init(_ package: String, _ name: String, _ bytes: Int64, _ sha256: String) {
            path = package + ".mlpackage/" + name
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    private struct Receipt: Codable {
        let revision: String
    }

    private nonisolated enum StoreError: LocalizedError {
        case invalidDownload
        case invalidModel
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .invalidDownload: "The voice download did not complete. Please retry."
            case .invalidModel: "The downloaded voice model did not pass verification. Please retry."
            case .insufficientSpace: "Free at least 820 MB of device storage, then try again."
            }
        }
    }
}

final class KokoroDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
