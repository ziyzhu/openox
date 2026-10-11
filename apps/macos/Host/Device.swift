import Foundation

nonisolated enum Device {
    static let hostKind = "macos"
    static let hostMode = "desktop"
    static let id = ProcessInfo.processInfo.hostName
    static var hostID: String { "macos:\(id)" }
    static var isInternal: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
