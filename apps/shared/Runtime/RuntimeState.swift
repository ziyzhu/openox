import Foundation

nonisolated enum RuntimeState: Equatable {
    case stopped
    case preparing
    case running
    case failed(String)
}
