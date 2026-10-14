import Foundation
import Network
import WebKit

enum BrowserNavigation {
    static func allowsServiceNavigation(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        #if targetEnvironment(simulator)
        if scheme == "http", isLoopback(host) { return true }
        #endif
        return scheme == "https" && !isPrivateNetwork(host)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        guard let address = IPv4Address(host) else { return false }
        return address.rawValue.first == 127
    }

    private static func isPrivateNetwork(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 4 else { return true }
            return bytes[0] == 10
                || bytes[0] == 127
                || bytes[0] == 0
                || bytes[0] == 169 && bytes[1] == 254
                || bytes[0] == 172 && (16...31).contains(bytes[1])
                || bytes[0] == 192 && bytes[1] == 168
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return true }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
                || bytes[0] & 0xfe == 0xfc
                || bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
        return false
    }
}

extension WebPage.NavigationError {
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case WebPage.NavigationError.failedProvisionalNavigation(let cause) = error {
            return isCancellation(cause)
        }
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
    }
}
