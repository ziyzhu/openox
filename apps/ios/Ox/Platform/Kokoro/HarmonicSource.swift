
import Foundation
import Accelerate


nonisolated public enum HarmonicConstants {
    public static let sampleRate: Double = 24000.0
    public static let upsampleScale: Int = 300
    public static var stftFramesPerXPreFrame: Int { upsampleScale / stftHop }
    public static let harmonicNum: Int = 8
    public static let harmonicDim: Int = 9
    public static let sineAmp: Float = 0.1
    public static let noiseStd: Float = 0.003
    public static let voicedThreshold: Float = 10.0
    public static let stftNfft: Int = 20
    public static let stftHop: Int = 5
    public static let stftFreqBins: Int = 11
    public static let harChannels: Int = 22
}

nonisolated private enum HarmonicSTFTBasis {
    static let window: [Float] = {
        let nfft = HarmonicConstants.stftNfft
        var values = [Float](repeating: 0, count: nfft)
        for n in 0..<nfft {
            values[n] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(n) / Float(nfft)))
        }
        return values
    }()

    static let real: [Float] = {
        buildBasis(imaginary: false)
    }()

    static let imaginary: [Float] = {
        buildBasis(imaginary: true)
    }()

    private static func buildBasis(imaginary: Bool) -> [Float] {
        let nfft = HarmonicConstants.stftNfft
        let freqBins = HarmonicConstants.stftFreqBins
        let twoPiOverN = 2.0 * Float.pi / Float(nfft)
        var basis = [Float](repeating: 0, count: freqBins * nfft)

        for k in 0..<freqBins {
            for n in 0..<nfft {
                let angle = twoPiOverN * Float(k) * Float(n)
                let trig = imaginary ? -sin(angle) : cos(angle)
                basis[k * nfft + n] = window[n] * trig
            }
        }
        return basis
    }
}


nonisolated public func f0Upsample(_ f0: [Float]) -> [Float] {
    let scale = HarmonicConstants.upsampleScale
    var result = [Float](repeating: 0, count: f0.count * scale)
    for (i, val) in f0.enumerated() {
        let start = i * scale
        for j in 0..<scale {
            result[start + j] = val
        }
    }
    return result
}


nonisolated public func sineGen(
    f0Upsampled: [Float],
    linearWeights: [Float],
    linearBias: Float,
    seed: UInt64? = nil
) -> [Float] {
    let L = f0Upsampled.count
    let dim = HarmonicConstants.harmonicDim // 9
    let sr = HarmonicConstants.sampleRate   // 24000.0
    let scale = HarmonicConstants.upsampleScale // 300
    let sineAmp = HarmonicConstants.sineAmp
    let noiseStd = HarmonicConstants.noiseStd
    let threshold = HarmonicConstants.voicedThreshold


    let downLen = max(1, (L + scale - 1) / scale)
    let upLen = downLen * scale

    var radValues = [Double](repeating: 0, count: L)
    var radDS = [Double](repeating: 0, count: downLen)
    var cumPhase = [Double](repeating: 0, count: downLen)
    var phaseScaled = [Double](repeating: 0, count: downLen)
    var phaseUp = [Double](repeating: 0, count: max(L, upLen))
    var sinResult = [Double](repeating: 0, count: L)
    var floatSines = [Float](repeating: 0, count: L)

    var sineWaves = [Float](repeating: 0, count: dim * L)

    var rng: RandomNumberGenerator = seed.map { SeededRNG(seed: $0) as RandomNumberGenerator } ?? SystemRandomNumberGenerator()

    let twoPiTimesScale = 2.0 * Double.pi * Double(scale)

    for h in 0..<dim {
        let invSr = Double(h + 1) / sr

        for t in 0..<L {
            let r = (Double(f0Upsampled[t]) * invSr).truncatingRemainder(dividingBy: 1.0)
            radValues[t] = r < 0 ? r + 1.0 : r
        }

        if h > 0 {
            radValues[0] += Double.random(in: 0..<1, using: &rng)
        }

        linearInterpolateInto(from: radValues, count: L, into: &radDS, targetLen: downLen)

        if downLen > 0 {
            cumPhase[0] = radDS[0]
            for t in 1..<downLen {
                cumPhase[t] = cumPhase[t - 1] + radDS[t]
            }
        }

        vDSP_vsmulD(cumPhase, 1, [twoPiTimesScale], &phaseScaled, 1, vDSP_Length(downLen))

        linearInterpolateInto(from: phaseScaled, count: downLen, into: &phaseUp, targetLen: upLen)

        var n = Int32(L)
        vvsin(&sinResult, phaseUp, &n)

        vDSP_vdpsp(sinResult, 1, &floatSines, 1, vDSP_Length(L))
        var ampScalar = sineAmp
        vDSP_vsmul(floatSines, 1, &ampScalar, &sineWaves[h * L], 1, vDSP_Length(L))
    }


    let unvoicedNoiseAmp = sineAmp / 3.0
    var uvMask = [Float](repeating: 0, count: L)
    var noiseAmp = [Float](repeating: 0, count: L)
    for t in 0..<L {
        let uv: Float = f0Upsampled[t] > threshold ? 1.0 : 0.0
        uvMask[t] = uv
        noiseAmp[t] = uv * noiseStd + (1.0 - uv) * unvoicedNoiseAmp
    }

    let totalNoise = dim * L
    var gaussianNoise = [Float](repeating: 0, count: totalNoise)
    generateGaussianNoise(into: &gaussianNoise, count: totalNoise, seed: seed)

    var maskedSine = [Float](repeating: 0, count: L)
    var scaledNoise = [Float](repeating: 0, count: L)
    sineWaves.withUnsafeMutableBufferPointer { sinePtr in
        gaussianNoise.withUnsafeBufferPointer { noisePtr in
            uvMask.withUnsafeBufferPointer { uvPtr in
                noiseAmp.withUnsafeBufferPointer { ampPtr in
                    maskedSine.withUnsafeMutableBufferPointer { maskedPtr in
                        scaledNoise.withUnsafeMutableBufferPointer { scaledPtr in
                            for h in 0..<dim {
                                let offset = h * L
                                let sineBase = sinePtr.baseAddress!.advanced(by: offset)
                                let noiseBase = noisePtr.baseAddress!.advanced(by: offset)
                                vDSP_vmul(sineBase, 1, uvPtr.baseAddress!, 1, maskedPtr.baseAddress!, 1, vDSP_Length(L))
                                vDSP_vmul(noiseBase, 1, ampPtr.baseAddress!, 1, scaledPtr.baseAddress!, 1, vDSP_Length(L))
                                vDSP_vadd(maskedPtr.baseAddress!, 1, scaledPtr.baseAddress!, 1, sineBase, 1, vDSP_Length(L))
                            }
                        }
                    }
                }
            }
        }
    }

    assert(linearWeights.count == dim, "Linear weights must have \(dim) elements")

    var merged = [Float](repeating: 0, count: L)
    linearWeights.withUnsafeBufferPointer { weightsPtr in
        sineWaves.withUnsafeBufferPointer { sinePtr in
            merged.withUnsafeMutableBufferPointer { mergedPtr in
                vDSP_mmul(
                    weightsPtr.baseAddress!, 1,
                    sinePtr.baseAddress!, 1,
                    mergedPtr.baseAddress!, 1,
                    1,
                    vDSP_Length(L),
                    vDSP_Length(dim)
                )
            }
        }
    }
    var bias = linearBias
    vDSP_vsadd(merged, 1, &bias, &merged, 1, vDSP_Length(L))
    var tanhCount = Int32(L)
    vvtanhf(&merged, merged, &tanhCount)

    return merged
}

nonisolated public func sineGenFromF0Frames(
    f0Frames: [Float],
    linearWeights: [Float],
    linearBias: Float,
    seed: UInt64? = nil
) -> [Float] {
    let frameCount = f0Frames.count
    let scale = HarmonicConstants.upsampleScale
    let L = frameCount * scale
    let dim = HarmonicConstants.harmonicDim
    let sr = HarmonicConstants.sampleRate
    let sineAmp = HarmonicConstants.sineAmp
    let noiseStd = HarmonicConstants.noiseStd
    let threshold = HarmonicConstants.voicedThreshold

    guard frameCount > 0 else { return [] }

    var rng: RandomNumberGenerator = seed.map { SeededRNG(seed: $0) as RandomNumberGenerator } ?? SystemRandomNumberGenerator()
    for _ in 1..<dim {
        _ = Double.random(in: 0..<1, using: &rng)
    }

    let unvoicedNoiseAmp = sineAmp / 3.0
    var uvMask = [Float](repeating: 0, count: L)
    var noiseAmp = [Float](repeating: 0, count: L)
    for (frame, f0) in f0Frames.enumerated() {
        let uv: Float = f0 > threshold ? 1.0 : 0.0
        let amp = uv * noiseStd + (1.0 - uv) * unvoicedNoiseAmp
        let start = frame * scale
        for j in 0..<scale {
            uvMask[start + j] = uv
            noiseAmp[start + j] = amp
        }
    }

    let totalNoise = dim * L
    var gaussianNoise = [Float](repeating: 0, count: totalNoise)
    var sineWaves = [Float](repeating: 0, count: dim * L)
    let twoPiTimesScale = 2.0 * Double.pi * Double(scale)
    let chunk = 65_536
    sineWaves.withUnsafeMutableBufferPointer { sinePtr in
        gaussianNoise.withUnsafeMutableBufferPointer { noisePtr in
            DispatchQueue.concurrentPerform(iterations: dim + 1) { task in
                if task == dim {
                    generateGaussianNoise(into: noisePtr, seed: seed)
                    return
                }
                let h = task
                let invSr = Double(h + 1) / sr
                var radDS = [Double](repeating: 0, count: frameCount)
                var cumPhase = [Double](repeating: 0, count: frameCount)
                var phaseScaled = [Double](repeating: 0, count: frameCount)
                for t in 0..<frameCount {
                    let r = (Double(f0Frames[t]) * invSr).truncatingRemainder(dividingBy: 1.0)
                    radDS[t] = r < 0 ? r + 1.0 : r
                }
                cumPhase[0] = radDS[0]
                for t in 1..<frameCount {
                    cumPhase[t] = cumPhase[t - 1] + radDS[t]
                }
                vDSP_vsmulD(cumPhase, 1, [twoPiTimesScale], &phaseScaled, 1, vDSP_Length(frameCount))

                let srcLen = Double(frameCount)
                let ratio = srcLen / Double(L)
                var phaseUp = [Double](repeating: 0, count: chunk)
                var sinResult = [Double](repeating: 0, count: chunk)
                var floatSines = [Float](repeating: 0, count: chunk)
                var ampScalar = sineAmp
                let sineBase = sinePtr.baseAddress!.advanced(by: h * L)
                var a = 0
                while a < L {
                    let b = min(a + chunk, L)
                    let n = b - a
                    for i in a..<b {
                        let srcIdx = (Double(i) + 0.5) * ratio - 0.5
                        let srcIdxClamped = max(0, min(srcIdx, srcLen - 1))
                        let lo = Int(srcIdxClamped)
                        let hi = min(lo + 1, frameCount - 1)
                        let frac = srcIdxClamped - Double(lo)
                        phaseUp[i - a] = phaseScaled[lo] * (1.0 - frac) + phaseScaled[hi] * frac
                    }
                    var count32 = Int32(n)
                    vvsin(&sinResult, phaseUp, &count32)
                    vDSP_vdpsp(sinResult, 1, &floatSines, 1, vDSP_Length(n))
                    vDSP_vsmul(floatSines, 1, &ampScalar, sineBase.advanced(by: a), 1, vDSP_Length(n))
                    a = b
                }
            }

            uvMask.withUnsafeBufferPointer { uvPtr in
                noiseAmp.withUnsafeBufferPointer { ampPtr in
                    DispatchQueue.concurrentPerform(iterations: dim) { h in
                        var maskedSine = [Float](repeating: 0, count: chunk)
                        var scaledNoise = [Float](repeating: 0, count: chunk)
                        let sineBase = sinePtr.baseAddress!.advanced(by: h * L)
                        let noiseBase = UnsafePointer(noisePtr.baseAddress!.advanced(by: h * L))
                        var a = 0
                        while a < L {
                            let n = min(chunk, L - a)
                            vDSP_vmul(sineBase.advanced(by: a), 1, uvPtr.baseAddress!.advanced(by: a), 1, &maskedSine, 1, vDSP_Length(n))
                            vDSP_vmul(noiseBase.advanced(by: a), 1, ampPtr.baseAddress!.advanced(by: a), 1, &scaledNoise, 1, vDSP_Length(n))
                            vDSP_vadd(maskedSine, 1, scaledNoise, 1, sineBase.advanced(by: a), 1, vDSP_Length(n))
                            a += n
                        }
                    }
                }
            }
        }
    }
    assert(linearWeights.count == dim, "Linear weights must have \(dim) elements")
    var merged = [Float](repeating: 0, count: L)
    linearWeights.withUnsafeBufferPointer { weightsPtr in
        sineWaves.withUnsafeBufferPointer { sinePtr in
            merged.withUnsafeMutableBufferPointer { mergedPtr in
                vDSP_mmul(
                    weightsPtr.baseAddress!, 1,
                    sinePtr.baseAddress!, 1,
                    mergedPtr.baseAddress!, 1,
                    1,
                    vDSP_Length(L),
                    vDSP_Length(dim)
                )
            }
        }
    }
    var bias = linearBias
    vDSP_vsadd(merged, 1, &bias, &merged, 1, vDSP_Length(L))
    var tanhCount = Int32(L)
    vvtanhf(&merged, merged, &tanhCount)

    return merged
}


nonisolated public func stftTransform(_ signal: [Float]) -> (magnitude: [Float], phase: [Float]) {
    let nfft = HarmonicConstants.stftNfft   // 20
    let hop = HarmonicConstants.stftHop     // 5
    let freqBins = HarmonicConstants.stftFreqBins // 11
    let padLen = nfft / 2                   // 10

    var padded = [Float](repeating: 0, count: signal.count + 2 * padLen)
    for i in 0..<padLen {
        padded[i] = signal[0]
    }
    for i in 0..<signal.count {
        padded[padLen + i] = signal[i]
    }
    let lastSample = signal.last ?? 0
    for i in 0..<padLen {
        padded[padLen + signal.count + i] = lastSample
    }

    let paddedLen = padded.count
    let nFrames = (paddedLen - nfft) / hop + 1

    var magnitude = [Float](repeating: 0, count: freqBins * nFrames)
    var phase = [Float](repeating: 0, count: freqBins * nFrames)
    var real = [Float](repeating: 0, count: nFrames)
    var imag = [Float](repeating: 0, count: nFrames)
    var magSquared = [Float](repeating: 0, count: nFrames)
    var eps = Float(1e-14)
    var vectorCount = Int32(nFrames)
    let frameCount = vDSP_Length(nFrames)

    padded.withUnsafeBufferPointer { paddedPtr in
        HarmonicSTFTBasis.real.withUnsafeBufferPointer { realBasisPtr in
            HarmonicSTFTBasis.imaginary.withUnsafeBufferPointer { imagBasisPtr in
                for k in 0..<freqBins {
                    let rowOffset = k * nFrames
                    let realFilter = realBasisPtr.baseAddress!.advanced(by: k * nfft)
                    let imagFilter = imagBasisPtr.baseAddress!.advanced(by: k * nfft)

                    real.withUnsafeMutableBufferPointer { realPtr in
                        vDSP_desamp(
                            paddedPtr.baseAddress!, vDSP_Stride(hop),
                            realFilter,
                            realPtr.baseAddress!,
                            frameCount,
                            vDSP_Length(nfft)
                        )
                    }
                    if k == 0 || k == freqBins - 1 {
                        vDSP_vclr(&imag, 1, vDSP_Length(nFrames))
                    } else {
                        imag.withUnsafeMutableBufferPointer { imagPtr in
                            vDSP_desamp(
                                paddedPtr.baseAddress!, vDSP_Stride(hop),
                                imagFilter,
                                imagPtr.baseAddress!,
                                frameCount,
                                vDSP_Length(nfft)
                            )
                        }
                    }

                    vDSP_vsq(real, 1, &magSquared, 1, frameCount)
                    vDSP_vma(imag, 1, imag, 1, magSquared, 1, &magSquared, 1, frameCount)
                    magnitude.withUnsafeMutableBufferPointer { magnitudePtr in
                        let magnitudeRow = magnitudePtr.baseAddress!.advanced(by: rowOffset)
                        vDSP_vsadd(magSquared, 1, &eps, magnitudeRow, 1, frameCount)
                        vvsqrtf(magnitudeRow, magnitudeRow, &vectorCount)
                    }
                    phase.withUnsafeMutableBufferPointer { phasePtr in
                        let phaseRow = phasePtr.baseAddress!.advanced(by: rowOffset)
                        vvatan2f(phaseRow, imag, real, &vectorCount)
                    }
                }
            }
        }
    }

    return (magnitude: magnitude, phase: phase)
}


nonisolated public struct HarDebugComponents: Sendable {
    public let harSource: [Float]
    public let magnitude: [Float]
    public let phase: [Float]
    public let har: [Float]
    public let nFrames: Int
}

nonisolated public func buildHar(
    f0Padded: [Float],
    linearWeights: [Float],
    linearBias: Float,
    seed: UInt64? = nil
) -> (har: [Float], nFrames: Int) {
    let components = buildHarComponents(
        f0Padded: f0Padded,
        linearWeights: linearWeights,
        linearBias: linearBias,
        seed: seed
    )
    return (har: components.har, nFrames: components.nFrames)
}

nonisolated public func buildHarComponents(
    f0Padded: [Float],
    linearWeights: [Float],
    linearBias: Float,
    seed: UInt64? = nil
) -> HarDebugComponents {
    let harSource = sineGenFromF0Frames(
        f0Frames: f0Padded,
        linearWeights: linearWeights,
        linearBias: linearBias,
        seed: seed
    )

    let (mag, ph) = stftTransform(harSource)
    let freqBins = HarmonicConstants.stftFreqBins // 11
    let nFrames = mag.count / freqBins

    var har = [Float](repeating: 0, count: HarmonicConstants.harChannels * nFrames)
    for k in 0..<freqBins {
        for t in 0..<nFrames {
            har[k * nFrames + t] = mag[k * nFrames + t]
        }
    }
    for k in 0..<freqBins {
        for t in 0..<nFrames {
            har[(freqBins + k) * nFrames + t] = ph[k * nFrames + t]
        }
    }

    return HarDebugComponents(
        harSource: harSource,
        magnitude: mag,
        phase: ph,
        har: har,
        nFrames: nFrames
    )
}


nonisolated func linearInterpolateDown(_ input: [Double], targetLen: Int) -> [Double] {
    if input.isEmpty || targetLen <= 0 { return [] }
    if targetLen == 1 {
        let sum = input.reduce(0, +)
        return [sum / Double(input.count)]
    }
    if input.count == targetLen { return input }

    var result = [Double](repeating: 0, count: targetLen)
    let srcLen = Double(input.count)
    let dstLen = Double(targetLen)

    for i in 0..<targetLen {
        let srcIdx = (Double(i) + 0.5) * srcLen / dstLen - 0.5
        let srcIdxClamped = max(0, min(srcIdx, srcLen - 1))
        let lo = Int(srcIdxClamped)
        let hi = min(lo + 1, input.count - 1)
        let frac = srcIdxClamped - Double(lo)
        result[i] = input[lo] * (1.0 - frac) + input[hi] * frac
    }
    return result
}

nonisolated func linearInterpolateUp(_ input: [Double], targetLen: Int) -> [Double] {
    return linearInterpolateDown(input, targetLen: targetLen)
}

nonisolated func linearInterpolateInto(from input: [Double], count srcCount: Int, into output: inout [Double], targetLen: Int) {
    if srcCount == 0 || targetLen <= 0 { return }
    if targetLen == 1 {
        var sum = 0.0
        for i in 0..<srcCount { sum += input[i] }
        output[0] = sum / Double(srcCount)
        return
    }
    if srcCount == targetLen {
        for i in 0..<srcCount { output[i] = input[i] }
        return
    }

    let srcLen = Double(srcCount)
    let dstLen = Double(targetLen)
    let ratio = srcLen / dstLen

    for i in 0..<targetLen {
        let srcIdx = (Double(i) + 0.5) * ratio - 0.5
        let srcIdxClamped = max(0, min(srcIdx, srcLen - 1))
        let lo = Int(srcIdxClamped)
        let hi = min(lo + 1, srcCount - 1)
        let frac = srcIdxClamped - Double(lo)
        output[i] = input[lo] * (1.0 - frac) + input[hi] * frac
    }
}


nonisolated struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        self.state = z == 0 ? 0x9E37_79B9_7F4A_7C15 : z
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

nonisolated func generateGaussianNoise(into buffer: inout [Float], count: Int, seed: UInt64? = nil) {
    buffer.withUnsafeMutableBufferPointer { ptr in
        generateGaussianNoise(into: UnsafeMutableBufferPointer(rebasing: ptr[0..<count]), seed: seed)
    }
}

nonisolated func generateGaussianNoise(into buffer: UnsafeMutableBufferPointer<Float>, seed: UInt64? = nil) {
    let count = buffer.count
    var rng = SeededRNG(seed: seed ?? UInt64.random(in: 0..<UInt64.max))
    let pairCount = (count + 1) / 2
    guard pairCount > 0 else { return }
    let scale = Float(0xFFFFFF)
    let tiny = Float.ulpOfOne
    var minusTwo = Float(-2.0)
    var twoPi = Float(2.0 * Float.pi)
    let chunkPairs = 32_768
    var u1 = [Float](repeating: 0, count: chunkPairs)
    var u2 = [Float](repeating: 0, count: chunkPairs)
    var radii = [Float](repeating: 0, count: chunkPairs)
    var theta = [Float](repeating: 0, count: chunkPairs)
    var cosTheta = [Float](repeating: 0, count: chunkPairs)
    var sinTheta = [Float](repeating: 0, count: chunkPairs)
    let out = buffer.baseAddress!
    var p0 = 0
    while p0 < pairCount {
        let n = min(chunkPairs, pairCount - p0)
        for i in 0..<n {
            u1[i] = max(tiny, Float(rng.next() & 0xFFFFFF) / scale)
            u2[i] = Float(rng.next() & 0xFFFFFF) / scale
        }
        var n32 = Int32(n)
        vvlogf(&radii, u1, &n32)
        vDSP_vsmul(radii, 1, &minusTwo, &radii, 1, vDSP_Length(n))
        vvsqrtf(&radii, radii, &n32)
        vDSP_vsmul(u2, 1, &twoPi, &theta, 1, vDSP_Length(n))
        vvcosf(&cosTheta, theta, &n32)
        vvsinf(&sinTheta, theta, &n32)
        vDSP_vmul(radii, 1, cosTheta, 1, out.advanced(by: 2 * p0), 2, vDSP_Length(n))
        let sinCount = min(n, count / 2 - p0)
        if sinCount > 0 {
            vDSP_vmul(radii, 1, sinTheta, 1, out.advanced(by: 2 * p0 + 1), 2, vDSP_Length(sinCount))
        }
        p0 += n
    }
}
