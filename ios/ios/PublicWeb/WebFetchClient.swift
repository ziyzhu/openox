import Darwin
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

nonisolated struct WebFetchRequest: Sendable {
    let url: URL

    init(url value: String) throws {
        guard let url = URL(string: value), WebFetchURLPolicy.allows(url) else { throw WebFetchError.invalidURL }
        self.url = url
    }
}

nonisolated struct WebFetchResponse: Sendable {
    let requestedURL: URL
    let url: URL
    let status: Int
    let statusText: String
    let headers: [String: String]
    let data: Data

    var ok: Bool { (200...299).contains(status) }
    var redirected: Bool { requestedURL != url }
    var mimeType: String {
        let value = headers["content-type"]?.split(separator: ";", maxSplits: 1).first
        return value.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "application/octet-stream"
    }
    var suggestedFilename: String { WebFetchFilename.make(url: url, mimeType: mimeType) }
    var kind: Artifact.Kind {
        if mimeType == "text/html" || mimeType == "application/xhtml+xml" { return .html }
        guard let type = UTType(mimeType: mimeType) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) { return .text }
        return .file
    }

    func json() -> JSONValue {
        .object([
            "ok": .bool(ok),
            "status": .int(status),
            "statusText": .string(statusText),
            "url": .string(url.absoluteString),
            "redirected": .bool(redirected),
            "headers": .object(headers.mapValues(JSONValue.string)),
        ])
    }
}

nonisolated enum WebFetchError: LocalizedError, Sendable {
    case invalidURL
    case responseTooLarge
    case executionTooLarge
    case invalidResponse
    case tooManyRedirects
    case invalidText

    var errorDescription: String? {
        switch self {
        case .invalidURL: "ox.web.fetch: url must be a public HTTP or HTTPS URL"
        case .responseTooLarge: "ox.web.fetch: response exceeded the 10 MiB limit"
        case .executionTooLarge: "ox.web.fetch: responses exceeded the 20 MiB execution limit"
        case .invalidResponse: "ox.web.fetch: server returned an invalid response"
        case .tooManyRedirects: "ox.web.fetch: response exceeded the five-redirect limit"
        case .invalidText: "HTTP response body is not valid text"
        }
    }
}

nonisolated enum WebAttachmentError: LocalizedError, Sendable {
    case tooMany
    case tooLarge
    case unsupportedImage(String)
    case contentTypeMismatch(String, String)
    case invalidImage
    case imageTooLarge
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .tooMany: "ox.artifact.attach: one JavaScript execution may attach at most four sources"
        case .tooLarge: "ox.artifact.attach: attachments exceeded the 20 MiB execution limit"
        case .unsupportedImage(let type): "ox.artifact.attach: unsupported image content type \(type)"
        case .contentTypeMismatch(let declared, let decoded): "ox.artifact.attach: declared content type \(declared) does not match \(decoded)"
        case .invalidImage: "ox.artifact.attach: response was not a supported raster image"
        case .imageTooLarge: "ox.artifact.attach: image exceeded the 40 megapixel limit"
        case .invalidPDF: "ox.artifact.attach: response was not a valid PDF"
        }
    }
}

nonisolated enum WebFetchURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        #if DEBUG && targetEnvironment(simulator)
        if let endpoint = SimEnv.servicesEndpoint,
           let endpointHost = endpoint.host?.lowercased(),
           host == endpointHost || ([host, endpointHost].allSatisfy { $0 == "127.0.0.1" || $0 == "localhost" }),
           url.port == endpoint.port { return true }
        #endif
        guard url.port == nil || url.port == 80 || url.port == 443 else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        if let address = ipv4(host) { return isPublic(address) }
        if let address = ipv6(host) { return isPublic(address) }
        return true
    }

    private static func ipv4(_ host: String) -> in_addr? {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1 ? address : nil
    }

    private static func ipv6(_ host: String) -> in6_addr? {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1 ? address : nil
    }

    private static func isPublic(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = value >> 24
        let second = (value >> 16) & 0xff
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        return true
    }

    private static func isPublic(_ address: in6_addr) -> Bool {
        var copy = address
        let bytes = withUnsafeBytes(of: &copy) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
        if bytes[0] == 0xff || bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
        if Array(bytes.prefix(12)) == Array(repeating: UInt8(0), count: 10) + [0xff, 0xff] {
            var mapped = in_addr()
            withUnsafeMutableBytes(of: &mapped) { $0.copyBytes(from: bytes.suffix(4)) }
            return isPublic(mapped)
        }
        return true
    }
}

nonisolated private final class WebFetchSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let redirects = Mutex(0)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = redirects.withLock { count in
            count += 1
            return count <= 5
        }
        completionHandler(allowed && request.url.map(WebFetchURLPolicy.allows) == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge,
            nil
        )
    }
}

actor WebFetchClient {
    static let shared = WebFetchClient()
    static let maximumBytes = 10 * 1_024 * 1_024

    func fetch(_ request: WebFetchRequest) async throws -> WebFetchResponse {
        let correlation = String(UUID().uuidString.prefix(8))
        let started = Date()
        Log.webFetch.info("fetch start id=\(correlation) url=\(LogPrivacy.url(request.url.absoluteString))")
        do {
            let response = try await performFetch(request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            Log.webFetch.info("fetch result id=\(correlation) status=\(response.status) bytes=\(response.data.count) type=\(LogPrivacy.text(response.mimeType)) kind=\(response.kind.rawValue) ms=\(elapsed)")
            return response
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            Log.webFetch.error("fetch failed id=\(correlation) ms=\(elapsed) error=\(LogPrivacy.text(error.localizedDescription))")
            throw error
        }
    }

    private func performFetch(_ request: WebFetchRequest) async throws -> WebFetchResponse {
        let delegate = WebFetchSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        let (bytes, rawResponse) = try await session.bytes(for: urlRequest)
        guard let response = rawResponse as? HTTPURLResponse,
              let finalURL = response.url,
              WebFetchURLPolicy.allows(finalURL) else { throw WebFetchError.invalidResponse }
        if (300...399).contains(response.statusCode) { throw WebFetchError.tooManyRedirects }
        if response.expectedContentLength > Self.maximumBytes { throw WebFetchError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), Self.maximumBytes)))
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw WebFetchError.responseTooLarge }
            data.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            guard name != "set-cookie" && name != "set-cookie2" else { continue }
            headers[name] = String(describing: value)
        }
        return WebFetchResponse(
            requestedURL: request.url,
            url: finalURL,
            status: response.statusCode,
            statusText: WebFetchStatus.text(response.statusCode),
            headers: headers,
            data: data
        )
    }
}

nonisolated enum WebFetchStatus {
    static func text(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}

nonisolated enum WebAttachmentFactory {
    static func make(response: WebFetchResponse, filename requestedName: String?) throws -> TransientAttachment {
        let declared = response.mimeType
        let detected = try inspectImage(response.data)
        let kind: TransientAttachment.Kind
        let mimeType: String
        let data: Data
        if declared.hasPrefix("image/") {
            guard let detected else {
                if declared == "image/svg+xml" { throw WebAttachmentError.unsupportedImage(declared) }
                throw WebAttachmentError.invalidImage
            }
            guard sameImageType(declared, detected.mimeType) else {
                throw WebAttachmentError.contentTypeMismatch(declared, detected.mimeType)
            }
            let prepared = try prepareImage(response.data)
            kind = .image
            mimeType = prepared.mimeType
            data = prepared.data
        } else if declared == "application/pdf" {
            try validatePDF(response.data)
            kind = .pdf
            mimeType = declared
            data = response.data
        } else if declared == "application/octet-stream", detected != nil {
            let prepared = try prepareImage(response.data)
            kind = .image
            mimeType = prepared.mimeType
            data = prepared.data
        } else if declared == "application/octet-stream", response.data.starts(with: Data("%PDF-".utf8)) {
            try validatePDF(response.data)
            kind = .pdf
            mimeType = "application/pdf"
            data = response.data
        } else if isText(declared) {
            kind = .text
            mimeType = declared
            data = response.data
        } else {
            kind = .file
            mimeType = declared
            data = response.data
        }
        let suggestedName = requestedName.map(ArtifactStore.sanitizedFilename)
            ?? WebFetchFilename.make(url: response.url, mimeType: mimeType)
        let filename = kind == .image
            ? PreparedImage(data: data, mimeType: mimeType, fileExtension: mimeType == "image/png" ? "png" : "jpg")
                .filename(from: suggestedName)
            : suggestedName
        return TransientAttachment(kind: kind, mimeType: mimeType, displayName: filename, data: data)
    }

    static func make(artifact: Artifact) throws -> TransientAttachment {
        guard artifact.exists else { throw ArtifactError.missing(artifact.fileName) }
        let data = try Data(contentsOf: artifact.fileURL)
        guard data.count <= WebFetchClient.maximumBytes else { throw WebAttachmentError.tooLarge }
        let response = WebFetchResponse(
            requestedURL: artifact.fileURL,
            url: artifact.fileURL,
            status: 200,
            statusText: "ok",
            headers: ["content-type": artifact.mimeType],
            data: data
        )
        return try make(response: response, filename: artifact.fileName)
    }

    private static func inspectImage(_ data: Data) throws -> ImagePreparer.Inspection? {
        do {
            return try ImagePreparer.inspect(data)
        } catch ImagePreparationError.invalid {
            return nil
        } catch ImagePreparationError.tooLarge {
            throw WebAttachmentError.imageTooLarge
        } catch {
            throw WebAttachmentError.invalidImage
        }
    }

    private static func prepareImage(_ data: Data) throws -> PreparedImage {
        do {
            return try ImagePreparer.prepare(data)
        } catch ImagePreparationError.tooLarge {
            throw WebAttachmentError.imageTooLarge
        } catch {
            throw WebAttachmentError.invalidImage
        }
    }

    private static func validatePDF(_ data: Data) throws {
        do {
            _ = try PDFPreparer.prepare(data)
        } catch {
            throw WebAttachmentError.invalidPDF
        }
    }

    private static func sameImageType(_ lhs: String, _ rhs: String) -> Bool {
        let aliases = ["image/jpg": "image/jpeg", "image/heif": "image/heic"]
        return (aliases[lhs] ?? lhs) == (aliases[rhs] ?? rhs)
    }

    private static func isText(_ type: String) -> Bool {
        type.hasPrefix("text/") || type == "application/json" || type.hasSuffix("+json")
            || type == "application/xml" || type.hasSuffix("+xml") || type == "application/javascript"
    }
}

nonisolated enum WebFetchFilename {
    static func make(url: URL, mimeType: String) -> String {
        let raw = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let safe = raw.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let type = UTType(mimeType: mimeType)
        let ext = type?.preferredFilenameExtension ?? "bin"
        guard safe.rangeOfCharacter(from: .alphanumerics) != nil else { return "web-response.\(ext)" }
        let bounded = String(safe.prefix(120))
        if let existing = UTType(filenameExtension: URL(fileURLWithPath: bounded).pathExtension),
           let type, existing.conforms(to: type) { return bounded }
        return "\(bounded).\(ext)"
    }
}
