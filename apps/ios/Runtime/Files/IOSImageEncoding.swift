import Foundation
import UIKit

nonisolated extension ImagePreparer {
    static func encode(_ image: CGImage, lossless: Bool) throws -> PreparedImage {
        try encode(UIImage(cgImage: image), lossless: lossless)
    }

    static func prepare(_ image: UIImage, suggestedName: String?) throws -> PreparedImage {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0 else { throw ImagePreparationError.invalid }
        let lossless = URL(fileURLWithPath: suggestedName ?? "").pathExtension.lowercased() == "png"
            || image.cgImage.map(hasAlpha) == true
        let longest = max(width, height)
        let scale = min(1, FileLimits.imageMaxDimension / CGFloat(max(1, longest)))
        let target = CGSize(width: max(1, CGFloat(width) * scale), height: max(1, CGFloat(height) * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !lossless
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return try encode(rendered, lossless: lossless)
    }

    private static func encode(_ image: UIImage, lossless: Bool) throws -> PreparedImage {
        if lossless {
            guard let data = image.pngData() else { throw ImagePreparationError.encode }
            return PreparedImage(data: data, mimeType: "image/png", fileExtension: "png")
        }
        guard let data = image.jpegData(compressionQuality: FileLimits.imageJPEGQuality) else {
            throw ImagePreparationError.encode
        }
        return PreparedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
    }
}

nonisolated extension FileImporter {
    public static func importImageAsync(_ image: UIImage, suggestedName: String?) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importImageAsync(image, suggestedName: suggestedName, in: scope)
    }

    static func importImageAsync(
        _ image: UIImage,
        suggestedName: String?,
        in scope: ProfileScope
    ) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDraft(image, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    static func imageDraft(_ image: UIImage, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(image, suggestedName: suggestedName)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw FileError.imageEncodeFailed
        } catch {
            throw FileError.imageDecodeFailed
        }
    }
}
