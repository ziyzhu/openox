import Foundation
import QuartzCore

@MainActor
final class MacStreamFrameDriver: StreamFrameDriving {
    private var task: Task<Void, Never>?
    private let handler: @MainActor (CFTimeInterval) -> Void

    init(handler: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.handler = handler
    }

    func start() -> Bool {
        guard task == nil else { return false }
        task = Task { [handler] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(33))
                    handler(CACurrentMediaTime())
                }
            } catch is CancellationError {
            } catch {
                Log.session.error("StreamFrameDriver failed error=\(error.localizedDescription)")
            }
        }
        return true
    }

    func stop() -> Bool {
        guard task != nil else { return false }
        task?.cancel()
        task = nil
        return true
    }
}
