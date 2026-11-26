import Compression
import CryptoKit
import Foundation

nonisolated enum ZipArchiveError: Error, Sendable {
    case tooLarge
    case invalidArchive
    case encrypted
    case unsupportedCompression
    case unsafePath
    case checksumMismatch
}

nonisolated enum ZipArchiveSource: Sendable {
    case data(Data)
    case file(URL)
}

nonisolated enum ZipArchiveCodec {
    struct File: Sendable, Equatable {
        let path: String
        let data: Data
    }

    private struct Entry {
        let path: String
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
        let externalAttributes: UInt32
    }

    static func encode(_ files: [File], maximumArchiveBytes: Int, progress: (Double) -> Void = { _ in }) throws -> Data {
        guard !files.isEmpty, files.count <= Int(UInt16.max) else { throw ZipArchiveError.invalidArchive }
        var archive = Data()
        var central = Data()
        var paths = Set<String>()

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            try validate(path: file.path, externalAttributes: 0)
            guard !file.path.hasSuffix("/"),
                  paths.insert(file.path.lowercased()).inserted,
                  let name = file.path.data(using: .utf8),
                  name.count <= Int(UInt16.max) else {
                throw ZipArchiveError.invalidArchive
            }
            let checksum = crc32(file.data)
            let size = try uint32(file.data.count)
            let localOffset = try uint32(archive.count)

            append(UInt32(0x04034b50), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0x0800), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(33), to: &archive)
            append(checksum, to: &archive)
            append(size, to: &archive)
            append(size, to: &archive)
            append(UInt16(name.count), to: &archive)
            append(UInt16(0), to: &archive)
            archive.append(name)
            archive.append(file.data)

            append(UInt32(0x02014b50), to: &central)
            append(UInt16(20), to: &central)
            append(UInt16(20), to: &central)
            append(UInt16(0x0800), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(33), to: &central)
            append(checksum, to: &central)
            append(size, to: &central)
            append(size, to: &central)
            append(UInt16(name.count), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(UInt32(0), to: &central)
            append(localOffset, to: &central)
            central.append(name)
            progress(Double(index + 1) / Double(files.count))

            guard archive.count + central.count + 22 <= maximumArchiveBytes else {
                throw ZipArchiveError.tooLarge
            }
        }

        let centralOffset = try uint32(archive.count)
        archive.append(central)
        append(UInt32(0x06054b50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(files.count), to: &archive)
        append(UInt16(files.count), to: &archive)
        append(try uint32(central.count), to: &archive)
        append(centralOffset, to: &archive)
        append(UInt16(0), to: &archive)
        guard archive.count <= maximumArchiveBytes else { throw ZipArchiveError.tooLarge }
        return archive
    }

    static func decode(
        _ data: Data,
        maximumArchiveBytes: Int,
        maximumEntryBytes: Int,
        maximumEntries: Int,
        maximumTotalBytes: Int = .max
    ) throws -> [File] {
        try decodeSources(data, maximumArchiveBytes: maximumArchiveBytes, maximumEntryBytes: maximumEntryBytes,
                          maximumEntries: maximumEntries, maximumTotalBytes: maximumTotalBytes).map { path, source in
            guard case .data(let body) = source else { throw ZipArchiveError.tooLarge }
            return File(path: path, data: body)
        }
    }

    static func decodeSources(
        _ data: Data,
        maximumArchiveBytes: Int,
        maximumEntryBytes: Int,
        maximumEntries: Int,
        maximumTotalBytes: Int = .max,
        spillAbove spillBytes: Int = .max,
        into spillDirectory: URL? = nil
    ) throws -> [(path: String, source: ZipArchiveSource)] {
        guard data.count <= maximumArchiveBytes else { throw ZipArchiveError.tooLarge }
        let end = try endRecord(in: data)
        let entryCount = Int(try readUInt16(data, at: end + 10))
        let centralSize = Int(try readUInt32(data, at: end + 12))
        let centralOffset = Int(try readUInt32(data, at: end + 16))
        guard entryCount > 0,
              entryCount <= maximumEntries,
              centralOffset >= 0,
              centralSize >= 0,
              centralOffset + centralSize <= end else {
            throw ZipArchiveError.invalidArchive
        }

        var entries: [Entry] = []
        var paths = Set<String>()
        var totalBytes = 0
        var cursor = centralOffset
        let centralEnd = centralOffset + centralSize
        for _ in 0..<entryCount {
            guard try readUInt32(data, at: cursor) == 0x02014b50,
                  cursor + 46 <= centralEnd else {
                throw ZipArchiveError.invalidArchive
            }
            let flags = try readUInt16(data, at: cursor + 8)
            let method = try readUInt16(data, at: cursor + 10)
            let compressedSize = Int(try readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(try readUInt32(data, at: cursor + 24))
            let nameLength = Int(try readUInt16(data, at: cursor + 28))
            let extraLength = Int(try readUInt16(data, at: cursor + 30))
            let commentLength = Int(try readUInt16(data, at: cursor + 32))
            let disk = try readUInt16(data, at: cursor + 34)
            let externalAttributes = try readUInt32(data, at: cursor + 38)
            let localOffset = Int(try readUInt32(data, at: cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard disk == 0,
                  nameLength > 0,
                  next <= centralEnd,
                  compressedSize <= maximumArchiveBytes,
                  uncompressedSize <= maximumEntryBytes,
                  uncompressedSize <= maximumTotalBytes - totalBytes else {
                throw ZipArchiveError.tooLarge
            }
            totalBytes += uncompressedSize
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw ZipArchiveError.unsafePath
            }
            try validate(path: path, externalAttributes: externalAttributes)
            guard paths.insert(path.lowercased()).inserted else { throw ZipArchiveError.invalidArchive }
            entries.append(Entry(
                path: path,
                flags: flags,
                method: method,
                checksum: try readUInt32(data, at: cursor + 16),
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localOffset: localOffset,
                externalAttributes: externalAttributes
            ))
            cursor = next
        }
        guard cursor == centralEnd else { throw ZipArchiveError.invalidArchive }

        return try entries.compactMap { entry in
            guard !isDirectory(entry) else { return nil }
            if entry.uncompressedSize > spillBytes, let spillDirectory {
                return (entry.path, .file(try spill(entry, from: data, before: centralOffset, into: spillDirectory)))
            }
            return (entry.path, .data(try extract(entry, from: data, before: centralOffset)))
        }
    }

    private static func endRecord(in data: Data) throws -> Int {
        guard data.count >= 22 else { throw ZipArchiveError.invalidArchive }
        let lowerBound = max(0, data.count - 65_557)
        var cursor = data.count - 22
        while cursor >= lowerBound {
            if try readUInt32(data, at: cursor) == 0x06054b50 {
                let commentLength = Int(try readUInt16(data, at: cursor + 20))
                let disk = try readUInt16(data, at: cursor + 4)
                let centralDisk = try readUInt16(data, at: cursor + 6)
                let diskEntries = try readUInt16(data, at: cursor + 8)
                let totalEntries = try readUInt16(data, at: cursor + 10)
                if cursor + 22 + commentLength == data.count,
                   disk == 0,
                   centralDisk == 0,
                   diskEntries == totalEntries,
                   totalEntries != UInt16.max {
                    return cursor
                }
            }
            cursor -= 1
        }
        throw ZipArchiveError.invalidArchive
    }

    private static func validate(path: String, externalAttributes: UInt32) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            throw ZipArchiveError.unsafePath
        }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZipArchiveError.unsafePath
        }
        let mode = UInt16(externalAttributes >> 16)
        guard mode & 0xf000 != 0xa000 else { throw ZipArchiveError.unsafePath }
    }

    private static func isDirectory(_ entry: Entry) -> Bool {
        entry.path.hasSuffix("/") || entry.externalAttributes & 0x10 != 0
    }

    private static func spill(_ entry: Entry, from data: Data, before centralOffset: Int, into directory: URL) throws -> URL {
        guard entry.method == 0 else { throw ZipArchiveError.tooLarge }
        let body = try bodyRange(entry, in: data, before: centralOffset)
        guard body.count == entry.uncompressedSize else { throw ZipArchiveError.invalidArchive }
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipArchiveError.invalidArchive }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var checksum = UInt32.max
        for start in stride(from: body.lowerBound, to: body.upperBound, by: 1024 * 1024) {
            try Task.checkCancellation()
            let chunk = data.subdata(in: start..<min(start + 1024 * 1024, body.upperBound))
            checksum = crc32Update(checksum, chunk)
            try handle.write(contentsOf: chunk)
        }
        guard ~checksum == entry.checksum else { throw ZipArchiveError.checksumMismatch }
        return url
    }

    private static func bodyRange(_ entry: Entry, in data: Data, before centralOffset: Int) throws -> Range<Int> {
        guard entry.flags & 0x0001 == 0 else { throw ZipArchiveError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipArchiveError.unsupportedCompression }
        guard entry.localOffset >= 0,
              entry.localOffset + 30 <= centralOffset,
              try readUInt32(data, at: entry.localOffset) == 0x04034b50 else {
            throw ZipArchiveError.invalidArchive
        }
        let localFlags = try readUInt16(data, at: entry.localOffset + 6)
        let localMethod = try readUInt16(data, at: entry.localOffset + 8)
        let nameLength = Int(try readUInt16(data, at: entry.localOffset + 26))
        let extraLength = Int(try readUInt16(data, at: entry.localOffset + 28))
        let nameStart = entry.localOffset + 30
        let nameEnd = nameStart + nameLength
        let start = nameEnd + extraLength
        let end = start + entry.compressedSize
        guard localFlags == entry.flags,
              localMethod == entry.method,
              nameEnd <= centralOffset,
              data.subdata(in: nameStart..<nameEnd) == Data(entry.path.utf8),
              start >= 0,
              end <= centralOffset else {
            throw ZipArchiveError.invalidArchive
        }
        return start..<end
    }

    private static func extract(_ entry: Entry, from data: Data, before centralOffset: Int) throws -> Data {
        let compressed = data.subdata(in: try bodyRange(entry, in: data, before: centralOffset))
        let body: Data
        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipArchiveError.invalidArchive }
            body = compressed
        } else {
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize + 1)
            let outputCapacity = output.count
            let decoded = compressed.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        outputCapacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        compressed.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded == entry.uncompressedSize else { throw ZipArchiveError.invalidArchive }
            body = Data(output.prefix(decoded))
        }
        guard crc32(body) == entry.checksum else { throw ZipArchiveError.checksumMismatch }
        return body
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipArchiveError.invalidArchive }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipArchiveError.invalidArchive }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func uint32(_ value: Int) throws -> UInt32 {
        guard let value = UInt32(exactly: value) else { throw ZipArchiveError.tooLarge }
        return value
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { checksum, _ in checksum & 1 == 1 ? 0xedb88320 ^ (checksum >> 1) : checksum >> 1 }
    }

    static func crc32Update(_ checksum: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            bytes.reduce(checksum) { crcTable[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~crc32Update(UInt32.max, data)
    }
}

nonisolated final class ZipArchiveWriter {
    private let handle: FileHandle
    private let maximumBytes: Int
    private var central = Data()
    private var offset = 0
    private var paths = Set<String>()

    init(url: URL, maximumBytes: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipArchiveError.invalidArchive }
        handle = try FileHandle(forWritingTo: url)
        self.maximumBytes = maximumBytes
    }

    deinit { try? handle.close() }

    func append(path: String, source: ZipArchiveSource) throws -> (bytes: Int, sha256: String) {
        try Task.checkCancellation()
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZipArchiveError.unsafePath
        }
        let name = Data(path.utf8)
        guard paths.insert(path.lowercased()).inserted, paths.count < Int(UInt16.max), name.count <= Int(UInt16.max) else {
            throw ZipArchiveError.invalidArchive
        }
        let reader: FileHandle?
        let size: Int
        switch source {
        case .data(let data): reader = nil; size = data.count
        case .file(let url): reader = try FileHandle(forReadingFrom: url); size = Int(try reader!.seekToEnd()); try reader!.seek(toOffset: 0)
        }
        defer { try? reader?.close() }
        guard let size32 = UInt32(exactly: size), let offset32 = UInt32(exactly: offset),
              offset + 30 + name.count + size + central.count + 46 + name.count + 22 <= maximumBytes else { throw ZipArchiveError.tooLarge }
        var header = Data()
        Self.append([UInt32(0x04034b50)], [UInt16(20), 0x0800, 0, 0, 33], to: &header)
        Self.append([UInt32(0), size32, size32], [UInt16(name.count), 0], to: &header)
        header.append(name)
        try handle.write(contentsOf: header)
        var checksum = UInt32.max
        var hash = SHA256()
        var written = 0
        while written < size {
            let chunk: Data
            switch source {
            case .data(let data): chunk = data.subdata(in: written..<min(written + 1024 * 1024, size))
            case .file: chunk = try reader!.read(upToCount: min(1024 * 1024, size - written)) ?? Data()
            }
            guard !chunk.isEmpty else { throw ZipArchiveError.invalidArchive }
            checksum = ZipArchiveCodec.crc32Update(checksum, chunk)
            hash.update(data: chunk)
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
        checksum = ~checksum
        let end = try handle.offset()
        try handle.seek(toOffset: UInt64(offset + 14))
        var crc = Data()
        Self.append([checksum], [], to: &crc)
        try handle.write(contentsOf: crc)
        try handle.seek(toOffset: end)
        Self.append([UInt32(0x02014b50)], [UInt16(20), 20, 0x0800, 0, 0, 33], to: &central)
        Self.append([checksum, size32, size32], [UInt16(name.count), 0, 0, 0, 0], to: &central)
        Self.append([UInt32(0), offset32], [], to: &central)
        central.append(name)
        offset = Int(end)
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func finish() throws {
        guard !paths.isEmpty, let centralOffset = UInt32(exactly: offset), let centralSize = UInt32(exactly: central.count) else {
            throw ZipArchiveError.invalidArchive
        }
        var end = central
        Self.append([UInt32(0x06054b50)], [UInt16(0), 0, UInt16(paths.count), UInt16(paths.count)], to: &end)
        Self.append([centralSize, centralOffset], [UInt16(0)], to: &end)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private static func append(_ words: [UInt32], _ halves: [UInt16], to data: inout Data) {
        for var value in words.map(\.littleEndian) { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        for var value in halves.map(\.littleEndian) { withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    }
}
