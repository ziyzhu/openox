import CoreGraphics
import Foundation

nonisolated struct PreparedPDF: Sendable {
    let data: Data
    let pageCount: Int
    let mimeType = "application/pdf"
}

nonisolated enum PDFPreparer {
    static func prepareFile(_ data: Data) throws -> PreparedPDF {
        guard data.count <= FileLimits.pdfBytes else {
            throw FileError.pdfTooLarge(bytes: data.count, limit: FileLimits.pdfBytes)
        }
        guard data.starts(with: Data("%PDF-".utf8)),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { throw FileError.invalidPDF }
        guard !document.isEncrypted else { throw FileError.encryptedPDF }
        return PreparedPDF(data: data, pageCount: document.numberOfPages)
    }
}
