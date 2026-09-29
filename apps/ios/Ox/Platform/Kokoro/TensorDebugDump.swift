
import CoreML
import Foundation

nonisolated public struct TensorDumpWriter {
    public let directory: URL
    private var records: [[String: Any]] = []

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public mutating func writeFloatArray(name: String, values: [Float], shape: [Int]) throws {
        try validateCount(name: name, count: values.count, shape: shape)
        let filename = "\(safeTensorName(name)).f32"
        var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: directory.appendingPathComponent(filename))
        records.append([
            "name": name,
            "dtype": "float32",
            "shape": shape,
            "path": filename,
            "summary": floatSummary(values),
        ])
    }

    public mutating func writeInt32Array(name: String, values: [Int32], shape: [Int]) throws {
        try validateCount(name: name, count: values.count, shape: shape)
        let filename = "\(safeTensorName(name)).i32"
        var data = Data(capacity: values.count * MemoryLayout<Int32>.size)
        for value in values {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        try data.write(to: directory.appendingPathComponent(filename))
        records.append([
            "name": name,
            "dtype": "int32",
            "shape": shape,
            "path": filename,
            "summary": intSummary(values),
        ])
    }

    public mutating func writeMLMultiArray(name: String, array: MLMultiArray) throws {
        let shape = array.shape.map { $0.intValue }
        switch array.dataType {
        case .int32:
            var values = [Int32]()
            values.reserveCapacity(array.count)
            for offset in 0..<array.count {
                values.append(array[multiIndex(offset: offset, shape: shape)].int32Value)
            }
            try writeInt32Array(name: name, values: values, shape: shape)
        default:
            let values = floatValues(from: array)
            try writeFloatArray(name: name, values: values, shape: shape)
        }
    }

    public mutating func writeManifest(metadata: [String: Any]) throws {
        let manifest: [String: Any] = [
            "schema_version": 1,
            "metadata": metadata,
            "tensors": records,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("tensor_manifest.json"))
    }

    private func validateCount(name: String, count: Int, shape: [Int]) throws {
        let expected = shape.reduce(1, *)
        guard count == expected else {
            throw TensorDumpError.invalidShape(name: name, count: count, expected: expected)
        }
    }
}

nonisolated public struct TensorDumpReader {
    public let directory: URL
    public let metadata: [String: Any]
    private let records: [String: TensorDumpRecord]

    public init(directory: URL) throws {
        self.directory = directory
        let manifestURL = directory.appendingPathComponent("tensor_manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = manifest["schema_version"] as? Int,
              schema == 1,
              let tensorRows = manifest["tensors"] as? [[String: Any]]
        else {
            throw TensorDumpError.invalidManifest(manifestURL.path)
        }
        self.metadata = manifest["metadata"] as? [String: Any] ?? [:]
        var parsed: [String: TensorDumpRecord] = [:]
        for row in tensorRows {
            guard let name = row["name"] as? String,
                  let dtype = row["dtype"] as? String,
                  let shape = row["shape"] as? [Int],
                  let path = row["path"] as? String
            else {
                throw TensorDumpError.invalidManifest(manifestURL.path)
            }
            parsed[name] = TensorDumpRecord(dtype: dtype, shape: shape, path: path)
        }
        self.records = parsed
    }

    public func readFloatArray(name: String) throws -> (values: [Float], shape: [Int]) {
        guard let record = records[name] else {
            throw TensorDumpError.missingTensor(name)
        }
        guard record.dtype == "float32" else {
            throw TensorDumpError.unsupportedDtype(name: name, dtype: record.dtype)
        }
        let url = directory.appendingPathComponent(record.path)
        let data = try Data(contentsOf: url)
        let expected = record.shape.reduce(1, *)
        guard data.count == expected * MemoryLayout<UInt32>.size else {
            throw TensorDumpError.invalidPayloadSize(
                name: name,
                bytes: data.count,
                expected: expected * MemoryLayout<UInt32>.size
            )
        }
        var values = [Float]()
        values.reserveCapacity(expected)
        for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size) {
            var bits: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bits) { raw in
                data.copyBytes(to: raw, from: offset..<(offset + MemoryLayout<UInt32>.size))
            }
            values.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        return (values, record.shape)
    }
}

nonisolated public struct TensorDumpRecord {
    public let dtype: String
    public let shape: [Int]
    public let path: String
}

nonisolated public enum TensorDumpError: Error, LocalizedError {
    case invalidShape(name: String, count: Int, expected: Int)
    case invalidManifest(String)
    case missingTensor(String)
    case unsupportedDtype(name: String, dtype: String)
    case invalidPayloadSize(name: String, bytes: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidShape(let name, let count, let expected):
            return "Tensor \(name) has \(count) values, expected \(expected) from shape"
        case .invalidManifest(let path):
            return "Invalid tensor dump manifest: \(path)"
        case .missingTensor(let name):
            return "Tensor dump is missing tensor \(name)"
        case .unsupportedDtype(let name, let dtype):
            return "Tensor \(name) has unsupported dtype \(dtype)"
        case .invalidPayloadSize(let name, let bytes, let expected):
            return "Tensor \(name) payload has \(bytes) bytes, expected \(expected)"
        }
    }
}

nonisolated public func makeFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
    let expected = shape.reduce(1, *)
    guard values.count == expected else {
        throw TensorDumpError.invalidShape(name: "MLMultiArray", count: values.count, expected: expected)
    }
    let arr = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
    let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
    _ = values.withUnsafeBufferPointer { src in
        memcpy(ptr, src.baseAddress!, values.count * MemoryLayout<Float>.size)
    }
    return arr
}

nonisolated private func safeTensorName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let safe = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
    return safe.isEmpty ? "tensor" : safe
}

nonisolated private func multiIndex(offset: Int, shape: [Int]) -> [NSNumber] {
    guard !shape.isEmpty else { return [] }
    var remainder = offset
    var result = [Int](repeating: 0, count: shape.count)
    for dimIndex in stride(from: shape.count - 1, through: 0, by: -1) {
        let dim = max(1, shape[dimIndex])
        result[dimIndex] = remainder % dim
        remainder /= dim
    }
    return result.map { NSNumber(value: $0) }
}

nonisolated private func floatSummary(_ values: [Float]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    let finite = values.filter { $0.isFinite }
    var summary: [String: Any] = [
        "count": values.count,
        "finite_count": finite.count,
        "nan_count": values.filter { $0.isNaN }.count,
        "inf_count": values.filter { $0.isInfinite }.count,
    ]
    guard !finite.isEmpty else { return summary }
    let minValue = finite.min() ?? 0
    let maxValue = finite.max() ?? 0
    let sum = finite.reduce(0.0) { $0 + Double($1) }
    let l2 = sqrt(finite.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(finite.count))
    summary["min"] = minValue
    summary["max"] = maxValue
    summary["mean"] = sum / Double(finite.count)
    summary["l2"] = l2
    return summary
}

nonisolated private func intSummary(_ values: [Int32]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? 0
    let sum = values.reduce(0) { $0 + Int64($1) }
    return [
        "count": values.count,
        "min": minValue,
        "max": maxValue,
        "mean": Double(sum) / Double(values.count),
    ]
}
