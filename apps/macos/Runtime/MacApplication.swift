import AppKit
import Darwin

@main
struct MacMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MacApplication()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class MacApplication: NSObject, NSApplicationDelegate {
    private var runtime: MacProfileRuntime?
    private var transport: ProfileServer?
    private var menu: MacMenu?
    private var startup: Task<Void, Never>?
    private var termination: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = MacProfileRuntime()
        ScheduleScheduler.shared.configure(runtime: runtime)
        let access = ConnectionAccess()
        let transport = ProfileServer(runtime: runtime, access: access)
        self.runtime = runtime
        self.transport = transport
        menu = MacMenu(runtime: runtime, access: access)
        PerfMonitor.shared.start()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                }
            }
            source.resume()
            signals.append(source)
        }
        startup = Task {
            do {
                try await runtime.prepare()
                try Task.checkCancellation()
                if ProcessInfo.processInfo.arguments.contains("--allow-connections") { access.allowsConnections = true }
                if ProcessInfo.processInfo.arguments.contains("--disable-connections") { access.allowsConnections = false }
                transport.reconcile()
                Log.app.info("MacApp prepared connectionsEnabled=\(access.allowsConnections)")
            } catch {
                Log.app.error("MacApp preparation failed error=\(error.localizedDescription)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard termination == nil else { return .terminateLater }
        Log.app.info("MacApp termination requested")
        startup?.cancel()
        transport?.stop()
        termination = Task {
            let scheduleShutdown = Task { await ScheduleScheduler.shared.stop() }
            let flushed = await runtime?.conversations.stopAllAndFlush() ?? true
            await scheduleShutdown.value
            Log.app.info("MacApp terminating flushed=\(flushed)")
            LogFile.shared.synchronize()
            if !flushed {
                termination = nil
                transport?.reconcile()
                do { try await ScheduleScheduler.shared.activate() }
                catch { Log.app.error("MacApp schedules resume failed error=\(error.localizedDescription)") }
            }
            sender.reply(toApplicationShouldTerminate: flushed)
        }
        return .terminateLater
    }
}
