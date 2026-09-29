
import CoreML
import Foundation

nonisolated public extension PipelineConstants {
    static let durationMultifunctionPackage = "kokoro_duration_multifunction.mlmodelc"
    static let f0ntrainMultifunctionPackage = "kokoro_f0ntrain_multifunction.mlmodelc"
    static let decoderPreMultifunctionPackage = "kokoro_decoder_pre_multifunction.mlmodelc"

    static func durationFunctionName(tokenLength: Int) -> String { "t\(tokenLength)" }
    static func f0ntrainFunctionName(tFrames: Int) -> String { "t\(tFrames)" }
    static func decoderPreFunctionName(bucketSec: Int) -> String { "bucket_\(bucketSec)s" }
}

nonisolated public struct MultifunctionPackage {
    public let packageURL: URL
    public let compiledURL: URL
    public let functionNames: Set<String>

    public static func open(at url: URL, cache: URL? = nil) throws -> MultifunctionPackage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard #available(macOS 15.0, iOS 18.0, *) else { return nil }
        let compiled = try CompiledModelCache.compiledURL(for: url, cache: cache) { (try? MLModelAsset(url: $0)) != nil }
        let asset = try MLModelAsset(url: compiled)
        let semaphore = DispatchSemaphore(value: 0)
        var names: [String] = []
        var failure: Error?
        asset.functionNames { result, error in
            if let result { names = result }
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
        return MultifunctionPackage(packageURL: url, compiledURL: compiled, functionNames: Set(names))
    }

    public func load(function name: String, computeUnits: MLComputeUnits) throws -> MLModel {
        guard functionNames.contains(name) else {
            throw PipelineError.modelNotLoaded("\(packageURL.lastPathComponent):\(name)")
        }
        guard #available(macOS 15.0, iOS 18.0, *) else {
            throw PipelineError.modelNotLoaded("\(packageURL.lastPathComponent):\(name) needs macOS 15 / iOS 18")
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.functionName = name
        return try MLModel(contentsOf: compiledURL, configuration: config)
    }
}
