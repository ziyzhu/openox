import Foundation

nonisolated enum HostState: Equatable {
    case stopped
    case preparing
    case running
    case failed(String)
}
