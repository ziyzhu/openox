#if targetEnvironment(simulator)
import Foundation

nonisolated enum SimEnv {
    static let servicesEndpoint = endpoint("OX_SERVICES_ENDPOINT")
    static let debugEndpoint = endpoint("OX_DEBUG_ENDPOINT")
    static let serviceProxyEndpoint = endpoint("OX_SERVICE_PROXY")
    static let webSearchEndpoint = endpoint("OX_WEB_SEARCH_ENDPOINT")
    static let iCloudDisabled = argument("--disable-icloud")
    static let mockLLMDisabled = argument("--disable-mock-llm")
    static let cloudOnlyArtifacts = values("OX_CLOUD_ONLY_ARTIFACTS")

    static func servicesURL(path: String) -> URL {
        let base = servicesEndpoint ?? URL(string: "http://127.0.0.1:8100/repository.git")!
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func argument(_ value: String) -> Bool {
        let enabled = ProcessInfo.processInfo.arguments.contains(value)
        if enabled { Log.app.info("SimEnv \(value)") }
        return enabled
    }

    private static func endpoint(_ key: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        guard let value = URL(string: raw), value.scheme != nil else {
            Log.app.warning("SimEnv \(key) is invalid")
            return nil
        }
        Log.app.info("SimEnv \(key) configured")
        return value
    }

    private static func flag(_ key: String) -> Bool {
        let enabled = ProcessInfo.processInfo.environment[key] == "1"
        if enabled { Log.app.info("SimEnv \(key)") }
        return enabled
    }

    private static func values(_ key: String) -> Set<String> {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return [] }
        let values = Set(raw.split(separator: ",").map(String.init))
        if !values.isEmpty { Log.app.info("SimEnv \(key) count=\(values.count)") }
        return values
    }
}
#endif
