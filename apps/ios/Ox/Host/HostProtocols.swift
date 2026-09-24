import Foundation

nonisolated enum HostProtocols {
    static let rpc = [1]
    static let repository = [1]
    static let action = [1, 2]
    static let skill = [1]

    static func unsupported(_ name: String, version: Int, supported: [Int]) -> String {
        "\(name) version \(version) is unsupported; this Ox supports \(supported.map(String.init).joined(separator: ", ")). Update Ox or target a supported version."
    }
}
