import Compression
import Foundation

nonisolated enum ZipArchiveError: Error, Sendable {
    case tooLarge
    case invalidArchive
    case encrypted
    case unsupportedCompression
    case unsafePath
    case checksumMismatch
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

    static func encode(_ files: [File], maximumArchiveBytes: Int) throws -> Data {
        guard !files.isEmpty, files.count <= Int(UInt16.max) else { throw ZipArchiveError.invalidArchive }
        var archive = Data()
        var central = Data()
        var paths = Set<String>()

        for file in files {
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
        maximumEntries: Int
    ) throws -> [File] {
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
                  uncompressedSize <= maximumEntryBytes else {
                throw ZipArchiveError.tooLarge
            }
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
            return File(path: entry.path, data: try extract(entry, from: data, before: centralOffset))
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

    private static func extract(_ entry: Entry, from data: Data, before centralOffset: Int) throws -> Data {
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
        let compressed = data.subdata(in: start..<end)
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

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(checksum & 1))
                checksum = checksum >> 1 ^ (0xedb88320 & mask)
            }
        }
        return ~checksum
    }
}
