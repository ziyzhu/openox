import Foundation
import WebKit

@MainActor
enum WebsiteAttachmentTransfer {
    static func stage(_ attachments: [WebsiteAttachment], on page: WebPage) async throws {
        _ = try await page.callJavaScript("window.__oxWebsiteFiles = []; return true;", arguments: [:], in: nil, contentWorld: .page)
        for attachment in attachments {
            _ = try await page.callJavaScript("window.__oxWebsiteChunks = []; return true;", arguments: [:], in: nil, contentWorld: .page)
            for offset in stride(from: 0, to: attachment.data.count, by: 256 * 1024) {
                try Task.checkCancellation()
                let chunk = attachment.data.subdata(in: offset..<min(offset + 256 * 1024, attachment.data.count))
                _ = try await page.callJavaScript(
                    "window.__oxWebsiteChunks.push(Uint8Array.from(atob(chunk), value => value.charCodeAt(0))); return true;",
                    arguments: ["chunk": chunk.base64EncodedString()], in: nil, contentWorld: .page
                )
            }
            _ = try await page.callJavaScript(
                "window.__oxWebsiteFiles.push(new File(window.__oxWebsiteChunks, name, {type: mimeType})); delete window.__oxWebsiteChunks; return true;",
                arguments: ["name": attachment.name, "mimeType": attachment.mimeType], in: nil, contentWorld: .page
            )
        }
    }
}
