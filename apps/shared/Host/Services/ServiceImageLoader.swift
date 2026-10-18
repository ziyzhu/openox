import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

nonisolated private final class ServiceImageSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let followsRedirects: Bool
    private let redirects = Mutex(0)

    init(followsRedirects: Bool) {
        self.followsRedirects = followsRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = redirects.withLock { count in
            count += 1
            return followsRedirects && count <= 5
                && request.url?.scheme?.lowercased() == "https"
                && request.url.map(WebFetchURLPolicy.allows) == true
        }
        if !allowed {
            Log.service.info("Service.icon rejected reason=redirectPolicy")
        }
        completionHandler(allowed ? request : nil)
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

nonisolated enum ServiceImageLoader {
    private static let maxBytes = 1 * 1_024 * 1_024

    private enum Failure: Error {
        case invalidURL
        case httpStatus(Int)
        case unsupportedType
        case byteLimit
        case pixelLimit
        case decode
    }

    static func data(
        icons: [RemoteMCPIcon],
        endpoint: URL,
        preferredTheme: String?
    ) async -> Data? {
        for icon in sorted(icons, preferredTheme: preferredTheme) {
            guard supports(icon.mimeType) else {
                Log.service.info("Service.icon rejected reason=unsupportedType")
                continue
            }
            if let data = dataURI(icon.src), let image = normalized(data) { return image }
            guard let url = URL(string: icon.src), allows(url, for: endpoint),
                  let data = await download(url, followsRedirects: false),
                  let image = normalized(data) else { continue }
            return image
        }
        return nil
    }

    static func data(url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https",
              WebFetchURLPolicy.allows(url),
              let data = await download(url, followsRedirects: true) else {
            Log.service.info("Service.icon rejected reason=urlOrDownload")
            return nil
        }
        return normalized(data)
    }

    private static func sorted(_ icons: [RemoteMCPIcon], preferredTheme: String?) -> [RemoteMCPIcon] {
        icons.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element, preferredTheme: preferredTheme)
            let right = rank(rhs.element, preferredTheme: preferredTheme)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private static func rank(_ icon: RemoteMCPIcon, preferredTheme: String?) -> Int {
        let theme = if icon.theme == preferredTheme { 3 } else if icon.theme == nil { 2 } else { 1 }
        let size = icon.sizes.compactMap { value -> Int? in
            let parts = value.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return min(width * height, 1_000_000)
        }.max() ?? 0
        return theme * 1_000_001 + size
    }

    private static func supports(_ mimeType: String?) -> Bool {
        guard let mimeType else { return true }
        return ["image/png", "image/jpeg", "image/jpg", "image/x-icon", "image/vnd.microsoft.icon"].contains(
            mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func dataURI(_ source: String) -> Data? {
        guard source.lowercased().hasPrefix("data:image/"),
              let comma = source.firstIndex(of: ",") else { return nil }
        let metadata = String(source[..<comma]).lowercased()
        guard metadata.hasSuffix(";base64"),
              supports(String(metadata.dropFirst(5).dropLast(7))),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
              data.count <= maxBytes else {
            Log.service.info("Service.icon rejected reason=invalidOrOversizedDataURI")
            return nil
        }
        return data
    }

    private static func download(_ url: URL, followsRedirects: Bool) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/png, image/jpeg, image/x-icon, image/vnd.microsoft.icon", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: ServiceImageSessionDelegate(followsRedirects: followsRedirects),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let response = rawResponse as? HTTPURLResponse,
                  let finalURL = response.url, WebFetchURLPolicy.allows(finalURL),
                  !followsRedirects || finalURL.scheme?.lowercased() == "https" else {
                throw Failure.invalidURL
            }
            guard (200...299).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
            guard supports(response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)) else {
                throw Failure.unsupportedType
            }
            guard response.expectedContentLength <= maxBytes else { throw Failure.byteLimit }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxBytes else { throw Failure.byteLimit }
                data.append(byte)
            }
            return data
        } catch {
            let reason = (error as? Failure).map { String(describing: $0) } ?? error.localizedDescription
            Log.service.error("Service.icon failed url=\(LogPrivacy.url(url.absoluteString)) reason=\(LogPrivacy.text(reason))")
            return nil
        }
    }

    private static func normalized(_ data: Data) -> Data? {
        do {
            return try decode(data)
        } catch {
            Log.service.info("Service.icon rejected reason=\(String(describing: error)) bytes=\(data.count)")
            return nil
        }
    }

    private static func decode(_ data: Data) throws -> Data {
        guard data.count <= maxBytes else { throw Failure.byteLimit }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.ico.identifier].contains(type) else {
            throw Failure.unsupportedType
        }
        let count = CGImageSourceGetCount(source)
        guard (1...32).contains(count), CGImageSourceGetStatus(source) == .statusComplete else {
            throw Failure.decode
        }
        var index = 0
        var largestArea = 0
        for frame in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw Failure.decode }
            guard width <= 4_096, height <= 4_096 else { throw Failure.pixelLimit }
            let area = width * height
            if area > largestArea {
                largestArea = area
                index = frame
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw Failure.decode
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.decode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.decode }
        Log.service.info("Service.icon decoded type=\(type) frame=\(index) width=\(image.width) height=\(image.height)")
        return output as Data
    }

    private static func allows(_ url: URL, for endpoint: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              let endpointHost = endpoint.host?.lowercased(),
              ServiceManager.websiteDataSite(for: host) == ServiceManager.websiteDataSite(for: endpointHost),
              WebFetchURLPolicy.allows(url) else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG && targetEnvironment(simulator)
        return url.scheme?.lowercased() == "http" && url.port == endpoint.port
        #else
        return false
        #endif
    }
}
