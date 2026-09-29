import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class KokoroMandarinModelStore {
    static let shared = KokoroMandarinModelStore()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case ready
        case failed(String)
    }

    nonisolated static let modelID = "kokoro-zh-zf-001-v1"
    nonisolated static let expectedBytes: Int64 = 92_826_823
    nonisolated static let revision = "006395f65025af251858b1ab0a7178a6a1e73f9f"

    nonisolated static let stages = [
        "KokoroAlbert.mlmodelc",
        "KokoroPostAlbert.mlmodelc",
        "KokoroAlignment.mlmodelc",
        "KokoroProsody_v2.mlmodelc",
        "KokoroNoise_v2.mlmodelc",
        "KokoroVocoder.mlmodelc",
        "KokoroTail_v2.mlmodelc",
    ]

    private struct Manifest: Decodable {
        let revision: String
        let files: [ModelFile]
    }

    private struct ModelFile: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    private struct Receipt: Codable {
        let revision: String
    }

    private(set) var state: State = .notInstalled
    private var operation: Task<Void, Never>?

    private var installationURL: URL {
        AppStoragePaths.models.appendingPathComponent(Self.modelID, isDirectory: true)
    }

    var assetsDirectory: URL? {
        guard state == .ready else { return nil }
        return installationURL
    }

    private init() {
        refresh()
    }

    func refresh() {
        guard operation == nil else { return }
        let root = AppStoragePaths.models
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("kokoro-zh-") && entry.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let receiptURL = installationURL.appendingPathComponent("receipt.json")
        let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        state = receipt?.revision == Self.revision
            && Self.stages.allSatisfy { FileManager.default.fileExists(atPath: installationURL.appendingPathComponent($0).path) }
            && FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("assets/pinyin_phrases.bin").path)
            && FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("assets/pinyin_single.bin").path)
            && FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("voices/zf_001.bin").path)
            && FileManager.default.fileExists(atPath: installationURL.appendingPathComponent("vocab.json").path)
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
                Log.ui.error("KokoroMandarin.download failed error=\(error.localizedDescription)")
            }
            operation = nil
        }
    }

    private func install() async throws {
        let assets = try KokoroAssets()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: assets.url("mandarin-manifest.json")))
        guard manifest.revision == Self.revision,
            manifest.files.reduce(Int64(0), { $0 + $1.bytes }) == Self.expectedBytes,
            manifest.files.allSatisfy({ !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") })
        else {
            throw StoreError.invalidModel
        }
        try ensureCapacity()
        let root = AppStoragePaths.models
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AppStoragePaths.excludeFromBackup(root)
        let stage = root.appendingPathComponent("kokoro-zh-" + UUID().uuidString + ".partial", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        var completedBytes: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = stage.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/FluidInference/kokoro-82m-coreml/resolve/\(Self.revision)/ANE-zh/\(file.path)?download=true")!
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

        try Task.checkCancellation()
        try JSONEncoder().encode(Receipt(revision: Self.revision)).write(
            to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        await KokoroMandarinTTS.shared.unload()
        if FileManager.default.fileExists(atPath: installationURL.path) {
            try FileManager.default.removeItem(at: installationURL)
        }
        try FileManager.default.moveItem(at: stage, to: installationURL)
        state = .ready
        Log.ui.info("KokoroMandarin.install model=\(Self.modelID) bytes=\(Self.expectedBytes)")
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
        guard size.map(Int64.init) == file.bytes,
            let stream = InputStream(url: url)
        else { throw StoreError.invalidModel }
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

    private nonisolated enum StoreError: LocalizedError {
        case invalidDownload
        case invalidModel
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .invalidDownload: "The Mandarin voice download did not complete. Please retry."
            case .invalidModel: "The Mandarin voice model did not pass verification. Please retry."
            case .insufficientSpace: "Free at least 550 MB of device storage, then try again."
            }
        }
    }
}
