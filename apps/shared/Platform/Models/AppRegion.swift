import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppRegion {
    static let shared = AppRegion()

    private(set) var region: LLMRegion
    @ObservationIgnored private var refreshTask: Task<LLMRegion?, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "ai.openox.region")
    @ObservationIgnored private var monitoring = false
    @ObservationIgnored private var fixedRegion: LLMRegion?

    private static let key = "app.region"
    nonisolated private static let detectionURL = URL(string: "https://cloudflare.com/cdn-cgi/trace")!

    private init() {
        fixedRegion = nil
        let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(LLMRegion.init(rawValue:))
        region = fixedRegion ?? stored ?? (Locale.current.region?.identifier == "CN" ? .china : .global)
        let source = fixedRegion == nil ? (stored == nil ? "locale-fallback" : "cached-network") : "simulator"
        Log.app.info("AppRegion ready region=\(region.rawValue) source=\(source)")
    }

    func start() {
        guard fixedRegion == nil else { return }
        guard !monitoring else { return }
        monitoring = true
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await AppRegion.shared.refresh() }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func refresh() async {
        if let refreshTask {
            _ = await refreshTask.value
            return
        }
        let task = Task { await Self.detect() }
        refreshTask = task
        let detected = await task.value
        refreshTask = nil
        guard fixedRegion == nil else { return }
        guard let detected else {
            Log.app.warning("AppRegion detection failed; keeping=\(region.rawValue)")
            return
        }
        let previous = region
        region = detected
        UserDefaults.standard.set(detected.rawValue, forKey: Self.key)
        Log.app.info("AppRegion detected region=\(detected.rawValue) changed=\(previous != detected)")
    }

    func setForTesting(_ value: LLMRegion) {
        fixedRegion = value
        refreshTask?.cancel()
        refreshTask = nil
        pathMonitor.cancel()
        monitoring = false
        region = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.key)
        Log.app.info("AppRegion test region=\(value.rawValue)")
    }

    nonisolated private static func detect() async -> LLMRegion? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            var request = URLRequest(url: detectionURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 8_192,
                  let body = String(data: data, encoding: .utf8),
                  let location = body.split(whereSeparator: { $0.isNewline })
                    .first(where: { $0.hasPrefix("loc=") })?
                    .dropFirst(4)
                    .uppercased(),
                  location.count == 2 else { return nil }
            return location == "CN" ? .china : .global
        } catch {
            return nil
        }
    }
}
