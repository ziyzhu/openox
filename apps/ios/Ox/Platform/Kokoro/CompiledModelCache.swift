
import CoreML
import Foundation

nonisolated enum CompiledModelCache {
    static func load(package: URL, configuration: MLModelConfiguration, cache: URL?) throws -> MLModel {
        if package.pathExtension == "mlmodelc" { return try MLModel(contentsOf: package, configuration: configuration) }
        guard let cache else {
            return try MLModel(contentsOf: MLModel.compileModel(at: package), configuration: configuration)
        }
        let cached = cachedURL(for: package, in: cache)
        if FileManager.default.fileExists(atPath: cached.path) {
            if let model = try? MLModel(contentsOf: cached, configuration: configuration) {
                return model
            }
            try? FileManager.default.removeItem(at: cached)
        }
        return try MLModel(contentsOf: compile(package, into: cache), configuration: configuration)
    }

    static func compiledURL(for package: URL, cache: URL?, isUsable: (URL) -> Bool) throws -> URL {
        if package.pathExtension == "mlmodelc" { return package }
        guard let cache else { return try MLModel.compileModel(at: package) }
        let cached = cachedURL(for: package, in: cache)
        if FileManager.default.fileExists(atPath: cached.path) {
            if isUsable(cached) { return cached }
            try? FileManager.default.removeItem(at: cached)
        }
        return try compile(package, into: cache)
    }

    private static func cachedURL(for package: URL, in cache: URL) -> URL {
        cache.appendingPathComponent(package.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mlmodelc")
    }

    private static func compile(_ package: URL, into cache: URL) throws -> URL {
        let compiled = try MLModel.compileModel(at: package)
        let cached = cachedURL(for: package, in: cache)
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: compiled, to: cached)
            return cached
        } catch {
            return compiled
        }
    }
}
