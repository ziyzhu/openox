import Foundation

nonisolated enum HostProtocols {
    static let repository = [3]

    static func unsupported(_ name: String, version: CustomStringConvertible, supported: [Int]) -> String {
        "\(name) version \(version) is unsupported; this Ox supports \(supported.map(String.init).joined(separator: ", ")). Update Ox or target a supported version."
    }
}
