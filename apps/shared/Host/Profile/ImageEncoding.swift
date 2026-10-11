import Foundation
import ImageIO

nonisolated protocol ImageEncoding {
    static func encode(_ image: CGImage, lossless: Bool) throws -> PreparedImage
}
