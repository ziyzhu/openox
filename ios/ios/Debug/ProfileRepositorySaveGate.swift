#if targetEnvironment(simulator)
import Foundation

nonisolated final class ProfileRepositorySaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var entered = false
    private var releaseSemaphore: DispatchSemaphore?

    var isEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func hold() {
        lock.lock()
        held = true
        entered = false
        releaseSemaphore = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    func release() {
        lock.lock()
        held = false
        entered = false
        let semaphore = releaseSemaphore
        releaseSemaphore = nil
        lock.unlock()
        semaphore?.signal()
    }

    func pass() {
        lock.lock()
        guard held, let semaphore = releaseSemaphore else {
            lock.unlock()
            return
        }
        entered = true
        lock.unlock()
        semaphore.wait()
    }
}
#endif
