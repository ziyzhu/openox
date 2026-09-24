import Foundation

nonisolated enum ServiceActionRuntime {
    private static let runtime: String = {
        guard let url = Bundle.main.url(forResource: "ServiceActionRuntime", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing ServiceActionRuntime.js")
        }
        return source
    }()

    static func source(domain: String) -> String {
        let data = try! JSONEncoder().encode(domain)
        let literal = String(decoding: data, as: UTF8.self)
        return "\(runtime)\nwindow.ox = window.__openOxCreateServiceRuntime(\(literal));"
    }
}
