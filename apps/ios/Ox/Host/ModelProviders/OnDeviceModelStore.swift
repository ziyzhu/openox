import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class OnDeviceModelStore {
    static let shared = OnDeviceModelStore()

    enum State: Equatable {
        case notInstalled
        case downloading(Double?)
        case verifying
        case ready
        case failed(String)
    }

    nonisolated static let modelID = "gemma-4-e2b-it"
    nonisolated static let modelName = "Gemma 4 E2B"
    nonisolated static let expectedBytes: Int64 = 2_588_147_712
    nonisolated static let expectedSHA256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    nonisolated static let revision = "6e5c4f1e395deb959c494953478fa5cec4b8008f"
    nonisolated static let sourceURL = URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/\(revision)/gemma-4-E2B-it.litertlm?download=true")!

    private(set) var state: State = .notInstalled
    private var operation: Task<Void, Never>?

    var modelURL: URL {
        AppStoragePaths.models.appendingPathComponent("\(Self.modelID).litertlm")
    }

    private var receiptURL: URL {
        AppStoragePaths.models.appendingPathComponent("\(Self.modelID).json")
    }

    private init() {
        refresh()
    }

    func refresh() {
        guard operation == nil else { return }
        let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let size = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        state = receipt?.sha256 == Self.expectedSHA256 && receipt?.revision == Self.revision
            && size.map(Int64.init) == Self.expectedBytes
            ? .ready : .notInstalled
    }

    func download() {
        guard operation == nil else { return }
        state = .downloading(nil)
        operation = Task {
            do {
                try ensureCapacity(for: Self.expectedBytes)
                let progress = ModelDownloadProgress { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                let (url, response) = try await URLSession.shared.download(for: URLRequest(url: Self.sourceURL), delegate: progress)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw ModelStoreError.invalidDownload
                }
                try await install(from: url, securityScoped: false)
            } catch {
                if Task.isCancelled {
                    state = .notInstalled
                } else {
                    Log.agent.error("OnDeviceModel.download failed error=\(error.localizedDescription)")
                    state = .failed(error.localizedDescription)
                }
            }
            operation = nil
        }
    }

    func importFile(_ url: URL) {
        guard operation == nil else { return }
        state = .verifying
        operation = Task {
            do {
                try await install(from: url, securityScoped: true)
            } catch {
                if Task.isCancelled {
                    state = .notInstalled
                } else {
                    Log.agent.error("OnDeviceModel.import failed error=\(error.localizedDescription)")
                    state = .failed(error.localizedDescription)
                }
            }
            operation = nil
        }
    }

    func cancel() {
        operation?.cancel()
    }

    func remove() async throws {
        guard operation == nil else { throw ModelStoreError.busy }
        state = .notInstalled
        await LiteRTRuntime.shared.unload()
        try? FileManager.default.removeItem(at: modelURL)
        try? FileManager.default.removeItem(at: receiptURL)
        Log.agent.info("OnDeviceModel.remove model=\(Self.modelID)")
    }

    private func install(from source: URL, securityScoped: Bool) async throws {
        let scoped = securityScoped && source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        if securityScoped { try ensureCapacity(for: Self.expectedBytes) }
        try manager.createDirectory(at: AppStoragePaths.models, withIntermediateDirectories: true)
        try AppStoragePaths.excludeFromBackup(AppStoragePaths.models)
        let staged = AppStoragePaths.models.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? manager.removeItem(at: staged) }
        state = .verifying
        let digest = try await Task.detached {
            if securityScoped {
                try FileManager.default.copyItem(at: source, to: staged)
            } else {
                try FileManager.default.moveItem(at: source, to: staged)
            }
            let size = (try staged.resourceValues(forKeys: [.fileSizeKey])).fileSize
            guard size.map(Int64.init) == Self.expectedBytes else { throw ModelStoreError.invalidModel }
            return try Self.digest(of: staged)
        }.value
        try Task.checkCancellation()
        guard digest == Self.expectedSHA256 else { throw ModelStoreError.invalidModel }
        try Task.checkCancellation()
        let size = (try staged.resourceValues(forKeys: [.fileSizeKey])).fileSize
        guard size.map(Int64.init) == Self.expectedBytes else { throw ModelStoreError.invalidModel }
        await LiteRTRuntime.shared.unload()
        if manager.fileExists(atPath: modelURL.path) { try manager.removeItem(at: modelURL) }
        try manager.moveItem(at: staged, to: modelURL)
        let receipt = Receipt(sha256: digest, revision: Self.revision)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        state = .ready
        LiteRTModelActivation.modelInstalled(at: modelURL)
        Log.agent.info("OnDeviceModel.install model=\(Self.modelID) bytes=\(Self.expectedBytes)")
    }

    private func ensureCapacity(for bytes: Int64) throws {
        let values = try AppStoragePaths.applicationSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes + 536_870_912 {
            throw ModelStoreError.insufficientSpace
        }
    }

    private nonisolated static func digest(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw ModelStoreError.invalidModel }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1_048_576)
            if count < 0 { throw stream.streamError ?? ModelStoreError.invalidModel }
            if count == 0 { break }
            hasher.update(data: Data(bytesNoCopy: buffer, count: count, deallocator: .none))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Receipt: Codable {
        let sha256: String
        let revision: String
    }

    private enum ModelStoreError: LocalizedError {
        case invalidDownload
        case invalidModel
        case busy
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .invalidDownload: "The model download did not complete. Please retry."
            case .invalidModel: "This file is not the supported Gemma 4 E2B model."
            case .busy: "Wait for the current model operation to finish."
            case .insufficientSpace: "Free at least 3.2 GB of device storage, then try again."
            }
        }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate {
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
