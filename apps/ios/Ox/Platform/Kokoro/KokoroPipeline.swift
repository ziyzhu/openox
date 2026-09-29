
import CoreML
import Foundation
import Accelerate


nonisolated public enum PipelineConstants {
    public static let sampleRate: Int = 24000
    public static let f0FrameRate: Double = 80.0
    public static let samplesPerDurationFrame: Int = sampleRate * 2 / Int(f0FrameRate)
    public static let durationTokenLength: Int = 128
    public static let voiceEmbeddingDim: Int = 256
    public static let styleDim: Int = 128
    public static let baselineDim: Int = 128
    public static let hiddenDim: Int = 640
    public static let textEncoderDim: Int = 512

    public static let tFramesForBucket: [Int: Int] = [
        3: 120, 7: 280, 10: 400, 15: 600, 30: 1200, 45: 1800,
    ]

    public static let defaultBuckets: [Int] = [3, 7, 10, 15, 30]
    public static let decoderPreComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    public static let durationTokenSizes: [Int] = [32, 64, 128, 256, 320, 384, 512]

    public static var maxDurationTokenLength: Int {
        durationTokenSizes.max() ?? 512
    }

    public static let maxCallerChunkTokens = 450

    public static let flexibleGeneratorPackage = "kokoro_decoder_har_post_range.mlmodelc"

    public static let flexibleGranuleSeconds: Double = 0.5
    public static var flexibleXPreGranuleFrames: Int { Int(flexibleGranuleSeconds * f0FrameRate) }
}


nonisolated public struct StageTimings {
    public var durationCoreML: Double = 0
    public var alignment: Double = 0
    public var matrixOps: Double = 0
    public var f0ntrainCoreML: Double = 0
    public var padding: Double = 0
    public var decoderPre: Double = 0
    public var hnsfSwift: Double = 0
    public var decoderPreHnsfOverlap: Double = 0
    public var generatorCoreML: Double = 0
    public var trim: Double = 0

    public var total: Double {
        durationCoreML + alignment + matrixOps + f0ntrainCoreML +
        padding + decoderPre + hnsfSwift - decoderPreHnsfOverlap +
        generatorCoreML + trim
    }

    public var preDecoder: Double {
        total - generatorCoreML - trim
    }
}

nonisolated public struct SynthesisResult {
    public let audio: [Float]
    public let timings: StageTimings
    public let bucketSeconds: Int
    public let audioDurationSeconds: Double
    public let wallTimeSeconds: Double
    public let predictedDurationFrames: Int
    public let predictedDurationTokens: Int
    public let durationModelCacheKey: String
    public let durationModelAllowsPadding: Bool
    public let durationTokenLength: Int
    public let tFrames: Int
    public let fullF0Length: Int
    public let decoderFrameCount: Int
    public let xPreExpectedTime: Int
    public let harExpectedTime: Int
    public let trimSampleCount: Int
    public let tokenDurationFrames: [Int]
}

nonisolated public struct DurationModelChoice {
    public let cacheKey: String
    public let tokenLength: Int
    public let packageURL: URL
    public let requiresAttentionMask: Bool
    public let allowsPadding: Bool
    public let functionName: String?

    public init(
        cacheKey: String,
        tokenLength: Int,
        packageURL: URL,
        requiresAttentionMask: Bool,
        allowsPadding: Bool,
        functionName: String? = nil
    ) {
        self.cacheKey = cacheKey
        self.tokenLength = tokenLength
        self.packageURL = packageURL
        self.requiresAttentionMask = requiresAttentionMask
        self.allowsPadding = allowsPadding
        self.functionName = functionName
    }
}


nonisolated public class KokoroPipeline: KokoroModelProvider {
    private static var generatorComputeUnits: MLComputeUnits {
        #if os(iOS)
        .cpuAndNeuralEngine
        #else
        .cpuAndGPU
        #endif
    }

    private let modelsDirectory: URL
    private let compiledModelCache: URL?
    private let durationChoices: [DurationModelChoice]
    private let f0ntrainMultifunction: MultifunctionPackage?
    private let decoderPreMultifunction: MultifunctionPackage?
    private let durationMultifunction: MultifunctionPackage?
    private let usesFlexibleGenerator: Bool
    private var openModels: [String: MLModel] = [:]
    private let lock = NSRecursiveLock()

    private let linearWeights: [Float]
    private let linearBias: Float

    private let availableBuckets: [Int]

    public init(
        modelsDirectory: URL,
        buckets: [Int] = PipelineConstants.defaultBuckets,
        linearWeights: [Float],
        linearBias: Float,
        compiledModelCache: URL? = nil
    ) throws {
        let directory = modelsDirectory.resolvingSymlinksInPath()
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        let durationChoices = Self.discoverDurationChoices(modelsDirectory: directory, compiledModelCache: compiledModelCache)
        guard !durationChoices.isEmpty else {
            throw PipelineError.modelNotLoaded("duration")
        }

        let f0Multi = try MultifunctionPackage.open(
            at: directory.appendingPathComponent(PipelineConstants.f0ntrainMultifunctionPackage), cache: compiledModelCache)
        let preMulti = try MultifunctionPackage.open(
            at: directory.appendingPathComponent(PipelineConstants.decoderPreMultifunctionPackage), cache: compiledModelCache)
        let durationMulti = durationChoices.contains { $0.functionName != nil }
            ? try MultifunctionPackage.open(
                at: directory.appendingPathComponent(PipelineConstants.durationMultifunctionPackage), cache: compiledModelCache)
            : nil

        var flexibleSupported = false
        if #available(macOS 15.0, iOS 18.0, *) { flexibleSupported = true }
        let usesFlexibleGenerator = flexibleSupported && exists(PipelineConstants.flexibleGeneratorPackage)

        let availableBuckets = buckets.filter { sec in
            guard let tFrames = PipelineConstants.tFramesForBucket[sec] else { return false }
            let hasF0 = f0Multi?.functionNames.contains(PipelineConstants.f0ntrainFunctionName(tFrames: tFrames)) == true
                || exists("kokoro_f0ntrain_t\(tFrames).mlmodelc")
            let hasPre = preMulti?.functionNames.contains(PipelineConstants.decoderPreFunctionName(bucketSec: sec)) == true
                || exists("kokoro_decoder_pre_\(sec)s.mlmodelc")
            let hasGenerator = usesFlexibleGenerator || exists("kokoro_decoder_har_post_\(sec)s.mlmodelc")
            return hasF0 && hasPre && hasGenerator
        }.sorted()
        if availableBuckets.isEmpty && !usesFlexibleGenerator && exists(PipelineConstants.flexibleGeneratorPackage) {
            throw PipelineError.modelNotLoaded(
                "\(PipelineConstants.flexibleGeneratorPackage) needs macOS 15 / iOS 18 and no kokoro_decoder_har_post_{N}s packages are present"
            )
        }

        self.modelsDirectory = directory
        self.compiledModelCache = compiledModelCache
        self.durationChoices = durationChoices
        self.f0ntrainMultifunction = f0Multi
        self.decoderPreMultifunction = preMulti
        self.durationMultifunction = durationMulti
        self.usesFlexibleGenerator = usesFlexibleGenerator
        self.availableBuckets = availableBuckets
        self.linearWeights = linearWeights
        self.linearBias = linearBias
    }

    public func synthesize(
        inputIds: [Int32],
        attentionMask: [Int32],
        refS: [Float],
        speed: Float = 1.0
    ) throws -> SynthesisResult {
        try autoreleasepool {
            var tensorDump: TensorDumpWriter? = nil
            return try executeKokoroSynthesis(
                request: KokoroSynthesisRequest(
                    inputIds: inputIds,
                    attentionMask: attentionMask,
                    refS: refS,
                    speed: speed
                ),
                modelProvider: self,
                linearWeights: linearWeights,
                linearBias: linearBias,
                tensorDump: &tensorDump
            )
        }
    }


    public static func loadFlexibleProgram(at url: URL, compiledModelCache: URL? = nil) throws -> MLModel? {
        guard #available(macOS 15.0, iOS 18.0, *),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = generatorComputeUnits
        return try CompiledModelCache.load(package: url, configuration: config, cache: compiledModelCache)
    }

    public static func discoverDurationChoices(
        modelsDirectory: URL,
        useExactDurationModels: Bool = ProcessInfo.processInfo.environment["KOKORO_USE_EXACT_DURATION_MODELS"] == "1",
        maxDurationTokenLength: Int? = nil,
        compiledModelCache: URL? = nil
    ) -> [DurationModelChoice] {
        var choices: [DurationModelChoice] = []
        let fm = FileManager.default
        let resolvedModelsDirectory = modelsDirectory.resolvingSymlinksInPath()
        func accepts(_ tokenLength: Int) -> Bool {
            guard let maxDurationTokenLength else { return true }
            return tokenLength <= maxDurationTokenLength
        }

        if useExactDurationModels, let urls = try? fm.contentsOfDirectory(
            at: resolvedModelsDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in urls {
                let name = url.lastPathComponent
                guard name.hasPrefix("kokoro_duration_exact_t"),
                      name.hasSuffix(".mlmodelc") else {
                    continue
                }
                let raw = name
                    .replacingOccurrences(of: "kokoro_duration_exact_t", with: "")
                    .replacingOccurrences(of: ".mlmodelc", with: "")
                guard let tokenLength = Int(raw) else { continue }
                guard accepts(tokenLength) else { continue }
                choices.append(DurationModelChoice(
                    cacheKey: "exact_t\(tokenLength)",
                    tokenLength: tokenLength,
                    packageURL: url,
                    requiresAttentionMask: false,
                    allowsPadding: false
                ))
            }
        }

        let multiURL = resolvedModelsDirectory.appendingPathComponent(PipelineConstants.durationMultifunctionPackage)
        let multi = try? MultifunctionPackage.open(at: multiURL, cache: compiledModelCache)
        for tokenLength in PipelineConstants.durationTokenSizes {
            guard accepts(tokenLength) else { continue }
            let functionName = PipelineConstants.durationFunctionName(tokenLength: tokenLength)
            if let multi, multi.functionNames.contains(functionName) {
                choices.append(DurationModelChoice(
                    cacheKey: "padded_t\(tokenLength)",
                    tokenLength: tokenLength,
                    packageURL: multiURL,
                    requiresAttentionMask: true,
                    allowsPadding: true,
                    functionName: functionName
                ))
                continue
            }
            let url = resolvedModelsDirectory.appendingPathComponent("kokoro_duration_t\(tokenLength).mlmodelc")
            if fm.fileExists(atPath: url.path) {
                choices.append(DurationModelChoice(
                    cacheKey: "padded_t\(tokenLength)",
                    tokenLength: tokenLength,
                    packageURL: url,
                    requiresAttentionMask: true,
                    allowsPadding: true
                ))
            }
        }

        let legacyURL = resolvedModelsDirectory.appendingPathComponent("kokoro_duration.mlmodelc")
        if fm.fileExists(atPath: legacyURL.path),
           !choices.contains(where: { $0.cacheKey == "padded_t128" }) {
            choices.append(DurationModelChoice(
                cacheKey: "padded_t128",
                tokenLength: PipelineConstants.durationTokenLength,
                packageURL: legacyURL,
                requiresAttentionMask: true,
                allowsPadding: true
            ))
        }

        return choices.sorted {
            if $0.tokenLength != $1.tokenLength {
                return $0.tokenLength < $1.tokenLength
            }
            return !$0.allowsPadding && $1.allowsPadding
        }
    }

    public static func selectDurationChoice(
        _ choices: [DurationModelChoice],
        actualTokens: Int
    ) throws -> DurationModelChoice {
        if let exact = choices.first(where: {
            !$0.allowsPadding && $0.tokenLength == actualTokens
        }) {
            return exact
        }

        if let padded = choices.first(where: {
            $0.allowsPadding && actualTokens <= $0.tokenLength
        }) {
            return padded
        }

        throw PipelineError.inputTooLong(
            tokens: actualTokens,
            maxTokens: choices.map { $0.tokenLength }.max() ?? 0
        )
    }

    public func durationModelChoices() -> [DurationModelChoice] {
        durationChoices
    }

    public func availableBucketSeconds() -> [Int] {
        availableBuckets
    }

    public func durationModel(choice: DurationModelChoice) throws -> MLModel {
        try open("duration.\(choice.cacheKey)") {
            if let function = choice.functionName, let durationMultifunction {
                return try durationMultifunction.load(function: function, computeUnits: .cpuAndGPU)
            }
            return try load(choice.packageURL, units: .cpuAndGPU)
        }
    }

    public func f0ntrainModel(tFrames: Int) throws -> MLModel {
        try open("f0ntrain.t\(tFrames)") {
            let function = PipelineConstants.f0ntrainFunctionName(tFrames: tFrames)
            if let f0ntrainMultifunction, f0ntrainMultifunction.functionNames.contains(function) {
                return try f0ntrainMultifunction.load(function: function, computeUnits: .cpuAndGPU)
            }
            return try load(package("kokoro_f0ntrain_t\(tFrames).mlmodelc"), units: .cpuAndGPU)
        }
    }

    public func decoderPreModel(bucketSec: Int) throws -> MLModel {
        try open("decoder_pre.\(bucketSec)s") {
            let units = PipelineConstants.decoderPreComputeUnits
            let function = PipelineConstants.decoderPreFunctionName(bucketSec: bucketSec)
            if let decoderPreMultifunction, decoderPreMultifunction.functionNames.contains(function) {
                return try decoderPreMultifunction.load(function: function, computeUnits: units)
            }
            return try load(package("kokoro_decoder_pre_\(bucketSec)s.mlmodelc"), units: units)
        }
    }

    public func generatorModel(bucketSec: Int) throws -> MLModel {
        try open("generator.\(bucketSec)s") {
            try load(package("kokoro_decoder_har_post_\(bucketSec)s.mlmodelc"), units: Self.generatorComputeUnits)
        }
    }

    public func flexibleGeneratorModel() throws -> MLModel? {
        guard usesFlexibleGenerator else { return nil }
        return try open("generator.range") {
            let url = package(PipelineConstants.flexibleGeneratorPackage)
            guard let model = try Self.loadFlexibleProgram(at: url, compiledModelCache: compiledModelCache) else {
                throw PipelineError.modelNotLoaded(PipelineConstants.flexibleGeneratorPackage)
            }
            return model
        }
    }

    public func prepareForBucket(bucketSec: Int, tFrames: Int) throws {
        _ = try f0ntrainModel(tFrames: tFrames)
        _ = try decoderPreModel(bucketSec: bucketSec)
        if try flexibleGeneratorModel() == nil {
            _ = try generatorModel(bucketSec: bucketSec)
        }
    }

    private func open(_ key: String, _ make: () throws -> MLModel) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model = openModels[key] { return model }
        let model = try make()
        openModels[key] = model
        return model
    }

    private func package(_ name: String) -> URL {
        modelsDirectory.appendingPathComponent(name)
    }

    private func load(_ url: URL, units: MLComputeUnits) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PipelineError.modelNotLoaded(url.deletingPathExtension().lastPathComponent)
        }
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try CompiledModelCache.load(package: url, configuration: config, cache: compiledModelCache)
    }
}


nonisolated public enum PipelineError: Error, LocalizedError {
    case noBucketAvailable
    case modelNotLoaded(String)
    case modelContractMismatch(String)
    case inputTooLong(tokens: Int, maxTokens: Int)

    public var errorDescription: String? {
        switch self {
        case .noBucketAvailable:
            return "No bucket available for the requested duration"
        case .modelNotLoaded(let name):
            return "Model not loaded: \(name)"
        case .modelContractMismatch(let message):
            return "Model contract mismatch: \(message)"
        case .inputTooLong(let tokens, let maxTokens):
            return "Input has \(tokens) tokens, but the largest loaded duration model supports \(maxTokens)"
        }
    }
}
