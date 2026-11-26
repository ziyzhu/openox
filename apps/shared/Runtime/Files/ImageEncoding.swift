import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated protocol ImageEncoding {
    static func encode(_ image: CGImage, lossless: Bool) throws -> PreparedImage
}

nonisolated struct PreparedImage: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String

    func filename(from suggestedName: String?) -> String {
        let suggested = FileStore.sanitizedFilename(suggestedName ?? "Image")
        let stem = URL(fileURLWithPath: suggested).deletingPathExtension().lastPathComponent
        return "\(stem).\(fileExtension)"
    }
}

nonisolated enum ImagePreparationError: Error {
    case invalid
    case tooLarge
    case encode
}

nonisolated enum ImagePreparer: ImageEncoding {
    struct Inspection {
        let mimeType: String
        let type: UTType
        let width: Int
        let height: Int
    }

    static func inspect(_ data: Data) throws -> Inspection {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              [.jpeg, .png, .gif, .webP, .heic, .heif].contains(where: { type.conforms(to: $0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImagePreparationError.invalid }
        guard width <= FileLimits.imagePixels / height else { throw ImagePreparationError.tooLarge }
        return Inspection(
            mimeType: type.preferredMIMEType ?? "image/unknown",
            type: type,
            width: width,
            height: height
        )
    }

    static func prepare(_ data: Data) throws -> PreparedImage {
        let inspection = try inspect(data)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ImagePreparationError.invalid
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(FileLimits.imageMaxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImagePreparationError.invalid
        }
        let lossless = inspection.type.conforms(to: .png)
            || inspection.type.conforms(to: .gif)
            || hasAlpha(image)
        return try encode(image, lossless: lossless)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: true
        }
    }
}
