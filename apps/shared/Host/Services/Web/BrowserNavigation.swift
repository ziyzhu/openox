import Foundation
import Network
import WebKit

enum BrowserNavigation {
    static func allowsServiceNavigation(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        #if targetEnvironment(simulator)
        if scheme == "http", isLoopback(url) { return true }
        #endif
        return scheme == "https" && WebFetchURLPolicy.hasPublicHost(url)
    }

    static func resolvesServiceNavigation(_ url: URL) async -> Bool {
        guard allowsServiceNavigation(url) else { return false }
        guard url.scheme?.lowercased() == "https" else { return true }
        return await WebFetchURLPolicy.resolvesPublicHost(url)
    }

    static func resolvesFrameNavigation(_ url: URL) async -> Bool {
        if ["data", "blob"].contains(url.scheme?.lowercased()) { return true }
        return await resolvesServiceNavigation(url)
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if host == "localhost" || host == "::1" { return true }
        guard let address = IPv4Address(host) else { return false }
        return address.rawValue.first == 127
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
