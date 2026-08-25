#if targetEnvironment(simulator)
import Foundation
import Network

@MainActor
final class WebSocketOxHostTransport {
    static let defaultPort = NWEndpoint.Port(
        rawValue: UInt16(SimEnv.debugEndpoint?.port ?? 9876)
    ) ?? 9876

    private let host: any OxHost
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "ox-host-websocket")

    init(host: any OxHost, port: NWEndpoint.Port = defaultPort) {
        self.host = host
        self.port = port
    }

    func start() {
        guard listener == nil else { return }
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in self.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in self.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
            Log.app.info("WebSocketOxHostTransport starting on ws://127.0.0.1:\(port)")
        } catch {
            Log.app.error("WebSocketOxHostTransport start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            Log.app.info("WebSocketOxHostTransport ready port=\(port)")
        case .failed(let error):
            Log.app.error("WebSocketOxHostTransport failed: \(error.localizedDescription)")
        case .cancelled:
            Log.app.info("WebSocketOxHostTransport cancelled")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            Task { @MainActor in
                self.handleConnectionState(connection, state: state, key: key)
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
        Log.app.info("WebSocketOxHostTransport client connected total=\(connections.count)")
    }

    private func handleConnectionState(
        _ connection: NWConnection,
        state: NWConnection.State,
        key: ObjectIdentifier
    ) {
        switch state {
        case .failed(let error):
            Log.app.warning("WebSocketOxHostTransport client failed: \(error.localizedDescription)")
            connections.removeValue(forKey: key)
        case .cancelled:
            connections.removeValue(forKey: key)
            Log.app.info("WebSocketOxHostTransport client closed total=\(connections.count)")
        default:
            break
        }
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let error {
                Log.app.warning("WebSocketOxHostTransport receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    OxHostProtocol.handle(data, host: self.host) { reply in
                        self.send(reply, on: connection)
                    }
                }
            }
            if connection.state == .ready {
                self.receive(on: connection)
            }
        }
    }

    nonisolated private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    Log.app.warning("WebSocketOxHostTransport send error: \(error.localizedDescription)")
                }
            }
        )
    }
}
#endif
