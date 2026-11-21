import Foundation

struct WhatsNewRelease: Identifiable, Codable, Equatable, Sendable {
    let version: String
    let notes: [String: [String]]

    var id: String { version }

    func items(for locale: Locale) -> [String] {
        let language = locale.language
        let script = language.script?.identifier
        let code = language.languageCode?.identifier
        let match = notes.keys.sorted().first { key in
            let candidate = Locale.Language(identifier: key)
            guard candidate.languageCode?.identifier == code else { return false }
            return script == nil || candidate.script?.identifier == nil || candidate.script?.identifier == script
        }
        return match.flatMap { notes[$0] } ?? notes["en-US"] ?? notes.values.first ?? []
    }
}

enum WhatsNew {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let endpoint = URL(string: "https://openox.ai/api/ios/versions")!
    private static let session = URLSession(configuration: .ephemeral)
    private static var catalogTask: Task<[WhatsNewRelease]?, Never>?

    private struct Response: Decodable {
        let versions: [WhatsNewRelease]
    }

    static func load() async -> [WhatsNewRelease]? {
        if let catalogTask { return await catalogTask.value }
        let task = Task { () -> [WhatsNewRelease]? in
            do {
                var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    Log.app.warning("WhatsNew.load failed status=\(status)")
                    catalogTask = nil
                    return nil
                }
                let releases = try JSONDecoder().decode(Response.self, from: data).versions
                Log.app.info("WhatsNew.load source=remote count=\(releases.count) newest=\(releases.first?.version ?? "none")")
                return releases
            } catch {
                Log.app.warning("WhatsNew.load failed error=\(error.localizedDescription)")
                catalogTask = nil
                return nil
            }
        }
        catalogTask = task
        return await task.value
    }

    static func shipped(_ releases: [WhatsNewRelease]) -> [WhatsNewRelease] {
        releases
            .filter { compare($0.version, appVersion) != .orderedDescending }
            .sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    static func isUnseen(since seenVersion: String?) -> Bool {
        guard let seenVersion else { return true }
        return compare(appVersion, seenVersion) == .orderedDescending
    }

    static func unseen(_ releases: [WhatsNewRelease], since seenVersion: String?) -> [WhatsNewRelease] {
        let unseen = shipped(releases).filter { release in
            if let seenVersion { return compare(release.version, seenVersion) == .orderedDescending }
            return release.version == appVersion
        }
        return unseen.contains { $0.version == appVersion } ? unseen : []
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
