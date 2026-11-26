import Foundation

nonisolated enum Device {
    static let hostKind = "macos"
    static let hostMode = "desktop"
    static let id = ProcessInfo.processInfo.hostName
    static var qualifiedID: String { "macos:\(id)" }
    static var name: String { Host.current().localizedName ?? id }
    static var isInternal: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
