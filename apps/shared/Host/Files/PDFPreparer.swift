import CoreGraphics
import Foundation

nonisolated struct PreparedPDF: Sendable {
    let data: Data
    let pageCount: Int
    let mimeType = "application/pdf"
}

nonisolated enum PDFPreparationError: Error {
    case invalid
    case encrypted
    case tooLarge
}

nonisolated enum PDFPreparer {
    static func prepare(_ data: Data) throws -> PreparedPDF {
        guard data.count <= FileLimits.pdfBytes else { throw PDFPreparationError.tooLarge }
        guard data.starts(with: Data("%PDF-".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { throw PDFPreparationError.invalid }
        guard !document.isEncrypted else { throw PDFPreparationError.encrypted }
        return PreparedPDF(data: data, pageCount: document.numberOfPages)
    }

    static func prepareFile(_ data: Data) throws -> PreparedPDF {
        do {
            return try prepare(data)
        } catch PDFPreparationError.tooLarge {
            throw FileError.pdfTooLarge(bytes: data.count, limit: FileLimits.pdfBytes)
        } catch PDFPreparationError.encrypted {
            throw FileError.encryptedPDF
        } catch {
            throw FileError.invalidPDF
        }
    }
}
