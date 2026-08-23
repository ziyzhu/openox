import CryptoKit
import Foundation
import Network
import PublicSuffixList
import WebKit

@MainActor
final class ServiceWebsiteDataCoordinator {
    private static let transferableDataTypes: Set<String> = [WKWebsiteDataTypeLocalStorage]

    private struct Snapshot: Codable {
        let version: Int
        let localStorage: Data
        let cookies: [CookieSnapshot]
    }

    private struct CookieSnapshot: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let version: Int
        let secure: Bool
        let httpOnly: Bool
        let sameSitePolicy: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expiresDate = cookie.expiresDate
            version = cookie.version
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sameSitePolicy = cookie.sameSitePolicy?.rawValue
        }

        func cookie() throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .version: String(version),
            ]
            if let expiresDate { properties[.expires] = expiresDate }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSitePolicy {
                properties[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSitePolicy)
            }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return cookie
        }
    }

    private var sharedDataStore: WKWebsiteDataStore?

    func makePageConfiguration() -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = true
        configuration.defaultNavigationPreferences.preferredContentMode = .desktop
        return configuration
    }

    nonisolated static func site(for domain: String) -> String {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !isIPAddress(normalized) else { return normalized }
        return PublicSuffixList.effectiveTLDPlusOne(normalized) ?? normalized
    }

    func clear(domain: String, services: [Service]) async {
        let site = Self.site(for: domain)
        let store = dataStore()
        quiesce(services, site: site)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeCookies])
        let records = await store.dataRecords(ofTypes: dataTypes).filter {
            Self.site(for: $0.displayName) == site
        }
        await store.removeData(ofTypes: dataTypes, for: records)
        let cookies = await clearCookies(for: site, in: store)
        Log.service.info("ServiceManager.clearWebsiteData domain=\(domain) site=\(site) records=\(records.count) cookies=\(cookies)")
    }

    func export(services: [Service]) async throws -> Data {
        quiesce(services)
        do {
            let store = dataStore()
            let localStorage = try await fetchWebsiteData(from: store)
            let cookies = await allCookies(in: store).map(CookieSnapshot.init)
            let snapshot = Snapshot(version: 1, localStorage: localStorage, cookies: cookies)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            Log.service.info("ServiceManager.websiteData exported scope=global bytes=\(data.count) cookies=\(cookies.count)")
            return data
        } catch {
            throw error
        }
    }

    func restore(_ data: Data, services: [Service]) async throws {
        let snapshot = try PropertyListDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let cookies = try snapshot.cookies.map { try $0.cookie() }
        quiesce(services)
        let store = dataStore()
        do {
            await store.removeData(ofTypes: Self.transferableDataTypes, modifiedSince: .distantPast)
            await clearCookies(in: store)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                store.restoreData(snapshot.localStorage) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            await setCookies(cookies, in: store)
            Log.service.info("ServiceManager.websiteData restored scope=global bytes=\(data.count) cookies=\(cookies.count)")
        } catch {
            throw error
        }
    }

    func logAuthRetention(domain: String, trigger: String, outcome: String, now: Date) async {
        let site = Self.site(for: domain)
        let cookies = await allCookies(in: dataStore()).filter {
            Self.site(for: $0.domain) == site
        }
        let session = cookies.filter { $0.isSessionOnly || $0.expiresDate == nil }
        let persistent = cookies.filter { !$0.isSessionOnly && $0.expiresDate != nil }
        let expired = persistent.filter { ($0.expiresDate ?? now) <= now }
        let nextExpirySeconds = persistent
            .compactMap(\.expiresDate)
            .filter { $0 > now }
            .map { Int($0.timeIntervalSince(now).rounded(.up)) }
            .min()
            .map(String.init) ?? "none"
        Log.service.info("Service.authRetention domain=\(domain) trigger=\(trigger) outcome=\(outcome) cookies=\(cookies.count) session=\(session.count) persistent=\(persistent.count) expired=\(expired.count) nextExpirySeconds=\(nextExpirySeconds)")
    }

    func cookies(for url: URL, serviceDomains: some Sequence<String>) async -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        guard let domain = serviceDomains
            .filter({ host == $0 || host.hasSuffix("." + $0) })
            .max(by: { $0.count < $1.count })
        else {
            Log.service.debug("ServiceManager.cookies no service owns host=\(host) — media plays unauthenticated")
            return []
        }
        let all = await allCookies(in: dataStore())
        let applicable = all.filter { cookie in
            let cookieDomain = (cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain).lowercased()
            return host == cookieDomain || host.hasSuffix("." + cookieDomain)
        }
        Log.service.info("ServiceManager.cookies url-host=\(host) domain=\(domain) matched=\(applicable.count)/\(all.count)")
        return applicable
    }

    private func dataStore() -> WKWebsiteDataStore {
        if let sharedDataStore { return sharedDataStore }
        let identifier = Self.dataStoreID
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        #if targetEnvironment(simulator)
        if let url = SimEnv.serviceProxyEndpoint,
           url.scheme == "http",
           let host = url.host,
           let endpointPort = NWEndpoint.Port(rawValue: UInt16(url.port ?? 8080)) {
            var proxy = ProxyConfiguration(
                httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(host), port: endpointPort),
                tlsOptions: nil
            )
            proxy.allowFailover = false
            store.proxyConfigurations = [proxy]
            Log.service.info("ServiceManager.dataStore proxy configured scope=global endpoint=\(host):\(endpointPort.rawValue)")
        }
        #endif
        sharedDataStore = store
        Log.service.info("ServiceManager.dataStore created scope=global id=\(identifier)")
        return store
    }

    nonisolated private static func isIPAddress(_ domain: String) -> Bool {
        if domain.contains(":") { return true }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy {
            guard let value = UInt8($0) else { return false }
            return String(value) == $0 || $0 == "0"
        }
    }

    nonisolated private static var dataStoreID: UUID {
        let digest = SHA256.hash(data: Data(AppConfiguration.websiteDataNamespace.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) })
    }

    private func allCookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func clearCookies(in store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore
        for cookie in await allCookies(in: store) {
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }
    }

    private func clearCookies(for site: String, in store: WKWebsiteDataStore) async -> Int {
        let cookieStore = store.httpCookieStore
        let cookies = await allCookies(in: store).filter {
            Self.site(for: $0.domain) == site
        }
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }
        return cookies.count
    }

    private func setCookies(_ cookies: [HTTPCookie], in store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func fetchWebsiteData(from store: WKWebsiteDataStore) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchData(of: Self.transferableDataTypes) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private func quiesce(_ services: [Service]) {
        for service in services { service.discardPages() }
    }

    private func quiesce(_ services: [Service], site: String) {
        for service in services where Self.site(for: service.domain) == site { service.discardPages() }
    }
}
