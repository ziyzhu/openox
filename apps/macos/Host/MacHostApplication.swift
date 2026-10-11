import AppKit
import Darwin

@main
struct MacHostMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MacHostApplication()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class MacHostApplication: NSObject, NSApplicationDelegate {
    private var host: HostRuntime?
    private var transport: WebSocketOxHostTransport?
    private var menu: MacHostMenu?
    private var startup: Task<Void, Never>?
    private var termination: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageMigrator.migrateApplicationStorage()
        let host = HostRuntime(
            serviceManager: ServiceManager(nativeServices: MacNativeServiceCatalog()),
            presentations: MacAppPresentations().presentations,
            conversationExecution: MacConversationExecution(),
            conversationFeedback: MacConversationFeedback(),
            executionPolicy: { true },
            activateSchedules: { try ScheduledSkillScheduler.shared.activate() }
        )
        ScheduledSkillScheduler.shared.configure(host: host)
        let access = HostAccess()
        if ProcessInfo.processInfo.arguments.contains("--allow-connections") { access.enabled = true }
        if ProcessInfo.processInfo.arguments.contains("--disable-connections") { access.enabled = false }
        let transport = WebSocketOxHostTransport(host: host, access: access)
        self.host = host
        self.transport = transport
        menu = MacHostMenu(host: host, access: access)
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
                try await host.prepare()
                try Task.checkCancellation()
                transport.reconcile()
                Log.app.info("MacHost prepared connectionsEnabled=\(access.enabled)")
            } catch {
                Log.app.error("MacHost preparation failed error=\(error.localizedDescription)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard termination == nil else { return .terminateLater }
        Log.app.info("MacHost termination requested")
        startup?.cancel()
        transport?.stop()
        termination = Task {
            let scheduleShutdown = Task { await ScheduledSkillScheduler.shared.stop() }
            let flushed = await host?.conversations.stopAllAndFlush() ?? true
            await scheduleShutdown.value
            Log.app.info("MacHost terminating flushed=\(flushed)")
            LogFile.shared.synchronize()
            if !flushed {
                termination = nil
                transport?.reconcile()
                do { try ScheduledSkillScheduler.shared.activate() }
                catch { Log.app.error("MacHost schedules resume failed error=\(error.localizedDescription)") }
            }
            sender.reply(toApplicationShouldTerminate: flushed)
        }
        return .terminateLater
    }
}
