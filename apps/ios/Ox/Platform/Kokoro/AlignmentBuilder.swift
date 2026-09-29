
import Foundation

nonisolated public func buildAlignmentMatrix(
    predDur: [Int],
    traceLength: Int,
    frameCount: Int
) -> [Float] {
    precondition(traceLength >= 1 && frameCount >= 1)

    var dur = [Int](repeating: 0, count: traceLength)
    let copyLen = min(traceLength, predDur.count)
    for i in 0..<copyLen {
        dur[i] = predDur[i]
    }

    var repeatIdx = [Int]()
    repeatIdx.reserveCapacity(frameCount)
    for (tokenIdx, count) in dur.enumerated() {
        for _ in 0..<count {
            repeatIdx.append(tokenIdx)
        }
    }

    if repeatIdx.count > frameCount {
        repeatIdx = Array(repeatIdx.prefix(frameCount))
    } else if repeatIdx.count < frameCount {
        let lastIdx = repeatIdx.last.map { min($0, traceLength - 1) } ?? 0
        let pad = frameCount - repeatIdx.count
        repeatIdx.append(contentsOf: [Int](repeating: lastIdx, count: pad))
    }

    for i in 0..<repeatIdx.count {
        repeatIdx[i] = max(0, min(repeatIdx[i], traceLength - 1))
    }

    var mat = [Float](repeating: 0, count: traceLength * frameCount)
    for frame in 0..<frameCount {
        let row = repeatIdx[frame]
        mat[row * frameCount + frame] = 1.0
    }

    return mat
}
