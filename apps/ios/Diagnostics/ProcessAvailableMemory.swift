import Foundation

nonisolated extension ProcessStats {
    static var availableMemoryMB: Double {
        Double(os_proc_available_memory()) / 1_048_576
    }
}
