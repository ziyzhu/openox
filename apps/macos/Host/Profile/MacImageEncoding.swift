import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated extension ImagePreparer {
    static func encode(_ image: CGImage, lossless: Bool) throws -> PreparedImage {
        let data = NSMutableData()
        let type = lossless ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImagePreparationError.encode
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: FileLimits.imageJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePreparationError.encode }
        return PreparedImage(data: data as Data, mimeType: lossless ? "image/png" : "image/jpeg", fileExtension: lossless ? "png" : "jpg")
    }
}
