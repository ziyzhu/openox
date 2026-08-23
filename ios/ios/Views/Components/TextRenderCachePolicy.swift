import CryptoKit
import Foundation

enum TextRenderCachePolicy {
    static let attributedLimit = 2 * 1_024 * 1_024
    static let parsedLimit = 1 * 1_024 * 1_024
    private static let attributedBytesPerUTF16Unit = 32
    private static let parsedBytesPerSourceByte = 4
    private static let parsedBytesPerBlock = 128

    static func key(_ value: String) -> NSString {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString() as NSString
    }

    static func attributedCost(utf16Count: Int) -> Int {
        max(1, utf16Count * attributedBytesPerUTF16Unit)
    }

    static func parsedCost(sourceByteCount: Int, blockCount: Int = 0) -> Int {
        max(1, sourceByteCount * parsedBytesPerSourceByte + blockCount * parsedBytesPerBlock)
    }
}
