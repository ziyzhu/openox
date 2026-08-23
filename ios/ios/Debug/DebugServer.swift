#if targetEnvironment(simulator)
import Foundation
import Network

@MainActor
final class DebugServer {
    static let shared = DebugServer()

    static let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: UInt16(SimEnv.debugEndpoint?.port ?? 9876)) ?? 9876

    typealias CommandHandler = @MainActor (Data, @escaping @MainActor (Data) -> Void) -> Void

    var onCommand: CommandHandler?
    var onConnect: (@MainActor () -> [Data])?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "debug-server")

    private init() {}

    func start() {
        guard listener == nil else { return }
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        do {
            let l = try NWListener(using: params, on: Self.port)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in self.handleListenerState(state) }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                Task { @MainActor in self.accept(conn) }
            }
            l.start(queue: queue)
            listener = l
            Log.app.info("DebugServer starting on ws://127.0.0.1:\(Self.port)")
        } catch {
            Log.app.error("DebugServer start failed: \(error.localizedDescription)")
        }
    }

    func broadcast(_ data: Data) {
        for conn in connections.values { send(data, on: conn) }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:  Log.app.info("DebugServer ready port=\(Self.port)")
        case .failed(let err): Log.app.error("DebugServer failed: \(err.localizedDescription)")
        case .cancelled: Log.app.info("DebugServer cancelled")
        default: break
        }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            Task { @MainActor in
                self.handleConnectionState(conn, state: state, key: key)
                if case .ready = state, let frames = self.onConnect?() {
                    for frame in frames { self.send(frame, on: conn) }
                }
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
        Log.app.info("DebugServer client connected total=\(connections.count)")
    }

    private func handleConnectionState(_ conn: NWConnection, state: NWConnection.State, key: ObjectIdentifier) {
        switch state {
        case .failed(let err):
            Log.app.warning("DebugServer client failed: \(err.localizedDescription)")
            connections.removeValue(forKey: key)
        case .cancelled:
            connections.removeValue(forKey: key)
            Log.app.info("DebugServer client closed total=\(connections.count)")
        default: break
        }
    }

    nonisolated private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if let error {
                Log.app.warning("DebugServer receive error: \(error.localizedDescription)")
                conn.cancel()
                return
            }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.onCommand?(data, { reply in self.send(reply, on: conn) })
                }
            }
            if conn.state == .ready { self.receive(on: conn) }
        }
    }

    nonisolated private func send(_ data: Data, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { err in
            if let err { Log.app.warning("DebugServer send error: \(err.localizedDescription)") }
        })
    }
}
#endif
