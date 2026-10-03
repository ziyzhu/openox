import Foundation

nonisolated extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

nonisolated enum ProcessStats {
    struct Sample {
        let cpuPercent: Double
        let footprintMB: Double
        let availableMB: Double
        let threadCount: Int

        var line: String {
            let avail = availableMB > 0 ? " avail=\(Int(availableMB))MB" : ""
            return "cpu=\(Int(cpuPercent))% mem=\(Int(footprintMB))MB\(avail) threads=\(threadCount)"
        }
    }

    static func sample() -> Sample {
        let (cpu, threads) = cpuPercentAndThreadCount()
        return Sample(cpuPercent: cpu,
                      footprintMB: footprintMB(),
                      availableMB: Double(os_proc_available_memory()) / 1_048_576,
                      threadCount: threads)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static func cpuPercentAndThreadCount() -> (Double, Int) {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return (0, 0) }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
        }
        return (total * 100, Int(count))
    }
}

nonisolated final class PerfMonitor: @unchecked Sendable {
    static let shared = PerfMonitor()

    private let sampleInterval: Duration = .seconds(2)
    private let heartbeatInterval: TimeInterval = 60
    private let cpuDeltaPercent = 10.0
    private let memDeltaMB = 50.0

    private var task: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var lastLogged: ProcessStats.Sample?
    private var lastLoggedAt = Date.distantPast

    func start() {
        guard task == nil else { return }
        let info = ProcessInfo.processInfo
        Log.perf.info("Perf.start cores=\(info.activeProcessorCount) thermal=\(info.thermalState.name) lowPower=\(info.isLowPowerModeEnabled)")
        watchMemoryPressure()
        watchProcessInfo()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: self?.sampleInterval ?? .seconds(2))
            }
        }
    }

    private func tick() {
        let s = ProcessStats.sample()
        guard shouldLog(s) else { return }
        lastLogged = s
        lastLoggedAt = Date()
        Log.perf.info("Perf.sample \(s.line)")
    }

    private func shouldLog(_ s: ProcessStats.Sample) -> Bool {
        guard let last = lastLogged else { return true }
        if Date().timeIntervalSince(lastLoggedAt) >= heartbeatInterval { return true }
        return abs(s.cpuPercent - last.cpuPercent) >= cpuDeltaPercent
            || abs(s.footprintMB - last.footprintMB) >= memDeltaMB
    }

    private func watchProcessInfo() {
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: nil) { _ in
            let state = ProcessInfo.processInfo.thermalState
            switch state {
            case .serious, .critical: Log.perf.warning("Perf.thermal state=\(state.name)")
            default:                  Log.perf.info("Perf.thermal state=\(state.name)")
            }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: nil) { _ in
            Log.perf.info("Perf.powerState lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let level = event.contains(.critical) ? "critical" : "warning"
            Log.perf.warning("Perf.memoryPressure level=\(level) \(ProcessStats.sample().line)")
        }
        source.activate()
        pressureSource = source
    }
}
