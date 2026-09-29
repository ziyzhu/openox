import CoreML
import Foundation

private enum MandarinStage: String, CaseIterable {
    case albert = "KokoroAlbert.mlmodelc"
    case postAlbert = "KokoroPostAlbert.mlmodelc"
    case alignment = "KokoroAlignment.mlmodelc"
    case prosody = "KokoroProsody_v2.mlmodelc"
    case noise = "KokoroNoise_v2.mlmodelc"
    case vocoder = "KokoroVocoder.mlmodelc"
    case tail = "KokoroTail_v2.mlmodelc"

    var computeUnits: MLComputeUnits {
        switch self {
        case .noise, .tail:
            #if targetEnvironment(simulator)
            return .cpuOnly
            #else
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .cpuOnly : .cpuAndGPU
            #endif
        default:
            return .cpuAndNeuralEngine
        }
    }
}

private enum MandarinArray {
    static func make(_ values: [Float], shape: [Int], type: MLMultiArrayDataType) throws -> MLMultiArray {
        guard shape.reduce(1, *) == values.count else { throw KokoroAssetError.invalid("Mandarin tensor shape") }
        let array = try allocate(shape, type: type)
        switch type {
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            for index in values.indices { pointer[index] = Float16(values[index]).bitPattern }
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            values.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { pointer.update(from: base, count: values.count) }
            }
        default:
            throw KokoroAssetError.invalid("Mandarin tensor type")
        }
        return array
    }

    static func make(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        guard shape.reduce(1, *) == values.count else { throw KokoroAssetError.invalid("Mandarin tensor shape") }
        let array = try allocate(shape, type: .int32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Int32.self)
        values.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { pointer.update(from: base, count: values.count) }
        }
        return array
    }

    static func copy(_ source: MLMultiArray, type: MLMultiArrayDataType) throws -> MLMultiArray {
        try make(floatValues(from: source), shape: source.shape.map(\.intValue), type: type)
    }

    private static func allocate(_ shape: [Int], type: MLMultiArrayDataType) throws -> MLMultiArray {
        let elementBytes = type == .float16 ? 2 : 4
        let bytes = shape.reduce(1, *) * elementBytes + 16_384
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        var strides = [Int](repeating: 1, count: shape.count)
        if shape.count > 1 {
            for index in stride(from: shape.count - 2, through: 0, by: -1) {
                strides[index] = strides[index + 1] * shape[index + 1]
            }
        }
        do {
            return try MLMultiArray(
                dataPointer: pointer,
                shape: shape.map(NSNumber.init(value:)),
                dataType: type,
                strides: strides.map(NSNumber.init(value:)),
                deallocator: { $0.deallocate() }
            )
        } catch {
            pointer.deallocate()
            throw error
        }
    }
}

actor KokoroMandarinPipeline {
    private var models: [MandarinStage: MLModel] = [:]

    func prepare(directory: URL) throws {
        guard models.isEmpty else { return }
        var loaded: [MandarinStage: MLModel] = [:]
        for stage in MandarinStage.allCases {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = stage.computeUnits
            configuration.allowLowPrecisionAccumulationOnGPU = true
            loaded[stage] = try MLModel(contentsOf: directory.appendingPathComponent(stage.rawValue), configuration: configuration)
        }
        models = loaded
        Log.ui.info("KokoroMandarin.prepare stages=\(models.count)")
    }

    func synthesize(ids: [Int32], voice: [Float], speed: Float) async throws -> [Float] {
        guard ids.count > 2, ids.count <= 512, voice.count == 256 else {
            throw KokoroAssetError.invalid("Mandarin model inputs")
        }
        let idsArray = try MandarinArray.make(ids, shape: [1, ids.count])
        let mask = try MandarinArray.make([Int32](repeating: 1, count: ids.count), shape: [1, ids.count])
        let styleS = try MandarinArray.make(Array(voice[128..<256]), shape: [1, 128], type: .float16)
        let timbre32 = try MandarinArray.make(Array(voice[0..<128]), shape: [1, 128], type: .float32)
        let timbre16 = try MandarinArray.make(Array(voice[0..<128]), shape: [1, 128], type: .float16)
        let speedArray = try MandarinArray.make([speed], shape: [1], type: .float16)

        let albert = try await predict(.albert, inputs: ["input_ids": idsArray, "attention_mask": mask])
        let bertDur = try MandarinArray.copy(output(albert, "bert_dur"), type: .float16)

        let post = try await predict(.postAlbert, inputs: [
            "bert_dur": bertDur,
            "input_ids": idsArray,
            "style_s": styleS,
            "speed": speedArray,
            "attention_mask": mask,
        ])
        let rawDurations = floatValues(from: try output(post, "duration"))
        guard rawDurations.allSatisfy(\.isFinite) else { throw KokoroAssetError.invalid("Mandarin durations") }
        let durations = rawDurations.map { Int32(min(max($0.rounded(), 1), 2_000)) }
        let frameCount = durations.reduce(0) { $0 + Int($1) }
        guard frameCount <= 2_000 else { throw KokoroAssetError.chunkTooLong }
        let durationArray = try MandarinArray.make(durations, shape: [1, durations.count])
        let d = try MandarinArray.copy(output(post, "d"), type: .float16)
        let tEn = try MandarinArray.copy(output(post, "t_en"), type: .float16)

        let alignment = try await predict(.alignment, inputs: ["pred_dur": durationArray, "d": d, "t_en": tEn])
        let en = try MandarinArray.copy(output(alignment, "en"), type: .float16)
        let asr = try MandarinArray.copy(output(alignment, "asr"), type: .float16)

        let prosody = try await predict(.prosody, inputs: ["en": en, "style_s": styleS])
        let f0 = try output(prosody, "F0")
        let n = try output(prosody, "N")
        let f032 = try MandarinArray.copy(f0, type: .float32)

        let noise = try await predict(.noise, inputs: ["F0_curve": f032, "style_timbre": timbre32])
        let f016 = try MandarinArray.copy(f0, type: .float16)
        let n16 = try MandarinArray.copy(n, type: .float16)
        let source0 = try MandarinArray.copy(output(noise, "x_source_0"), type: .float16)
        let source1 = try MandarinArray.copy(output(noise, "x_source_1"), type: .float16)

        let vocoder = try await predict(.vocoder, inputs: [
            "asr": asr,
            "F0_curve": f016,
            "N_pred": n16,
            "x_source_0": source0,
            "x_source_1": source1,
            "style_timbre": timbre16,
        ])
        let xPre = try MandarinArray.copy(output(vocoder, "x_pre"), type: .float32)
        let tail = try await predict(.tail, inputs: ["x_pre": xPre])
        let samples = floatValues(from: try output(tail, "audio"))
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw KokoroAssetError.invalid("Mandarin audio")
        }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        Log.ui.info("KokoroMandarin.chunk tokens=\(ids.count) frames=\(frameCount) samples=\(samples.count) peak=\(peak) rms=\(rms)")
        guard peak > 0.0001, rms > 0.00001 else { throw KokoroAssetError.silentAudio }
        guard peak < 2 else { throw KokoroAssetError.invalid("Mandarin waveform level") }
        return samples
    }

    private func predict(_ stage: MandarinStage, inputs: [String: MLMultiArray]) async throws -> MLFeatureProvider {
        try Task.checkCancellation()
        guard let model = models[stage] else { throw KokoroAssetError.missing(stage.rawValue) }
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        do {
            return try await model.prediction(from: provider)
        } catch {
            Log.ui.error("KokoroMandarin.stage failed stage=\(stage) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw KokoroAssetError.missing("Mandarin model output \(name)")
        }
        return value
    }
}
