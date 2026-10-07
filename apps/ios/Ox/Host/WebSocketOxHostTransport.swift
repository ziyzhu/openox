import Foundation
import Network
import UIKit

@MainActor
final class WebSocketOxHostTransport {
    nonisolated static let configuredPort: NWEndpoint.Port? = {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["OX_HOST_ENDPOINT"] ?? environment["OX_DEBUG_ENDPOINT"],
              let url = URL(string: raw), url.scheme == "ws",
              let value = url.port.flatMap(UInt16.init(exactly:)), value > 0 else { return nil }
        return NWEndpoint.Port(rawValue: value)
    }()
    nonisolated static let defaultPort = configuredPort ?? NWEndpoint.Port(rawValue: 9876)!

    private struct Client {
        let connection: NWConnection
        let scope: ProfileScope?
        let ingress: HostTransportIngress
        let address: String
        var pending = 0
    }

    private let host: any OxHost
    private let access: HostAccess
    private var prepared = false
    let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "ox-host-websocket")
    private var monitor: NWPathMonitor?
    private var addressPoll: DispatchSourceTimer?
    private var path: NWPath?
    private var ingress: HostTransportIngress?
    private var listeners: [String: NWListener] = [:]
    private var connections: [ObjectIdentifier: Client] = [:]

    init(host: any OxHost, access: HostAccess, port: NWEndpoint.Port = defaultPort) {
        self.host = host
        self.access = access
        self.port = port
        access.onEnabledChange = { [weak self] enabled in
            if enabled { self?.start() } else { self?.stop() }
        }
    }

    func activate() {
        prepared = true
        start()
    }

    private func start() {
        guard access.enabled, prepared, UIApplication.shared.applicationState == .active,
              monitor == nil else { return }
        let monitor = HostTransportIngress.pathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            Task { @MainActor in
                guard let self, let monitor, self.monitor === monitor else { return }
                self.path = path
                Log.app.info("WebSocketOxHostTransport path status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ","))")
                self.refreshIngress()
            }
        }
        // Address changes on an existing VPN do not always change the default path.
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        poll.setEventHandler { [weak self, weak monitor] in
            Task { @MainActor in
                guard let self, let monitor, self.monitor === monitor else { return }
                self.refreshIngress()
            }
        }
        addressPoll = poll
        poll.resume()
        monitor.start(queue: queue)
        Log.app.info("WebSocketOxHostTransport starting mode=\(HostTransportIngress.loopbackEnabled ? "debug-simulator-loopback" : "tailscale") port=\(port)")
    }

    private func refreshIngress() {
        guard let path, UIApplication.shared.applicationState == .active else { return }
        let next = HostTransportIngress.current(on: path)
        guard next != ingress else { return }
        closeListeners()
        ingress = next
        guard let next else {
            Log.app.info("WebSocketOxHostTransport unavailable: Tailscale ingress lost or ambiguous")
            return
        }
        for address in next.addresses { listen(on: address, ingress: next) }
    }

    private func listen(on address: String, ingress: HostTransportIngress) {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 96 * 1024 * 1024
        // CLI/native Clients omit Origin. Do not let a website use a trusted node's access.
        webSocket.setClientRequestHandler(queue) { _, headers in
            let browser = headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
            if browser { Log.app.warning("WebSocketOxHostTransport rejected browser origin") }
            return NWProtocolWebSocket.Response(status: browser ? .reject : .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        ingress.constrain(parameters)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: port)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listeners[address] === listener else { return }
                    switch state {
                    case .ready:
                        Log.app.info("WebSocketOxHostTransport ready mode=\(ingress.description) address=\(address) port=\(self.port)")
                    case .failed(let error):
                        self.closeListeners()
                        Log.app.warning("WebSocketOxHostTransport failed error=\(error.localizedDescription); reopen Ox to retry")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listeners[address] === listener else { connection.cancel(); return }
                    self.accept(connection, ingress: ingress, address: address)
                }
            }
            listeners[address] = listener
            listener.start(queue: queue)
        } catch {
            closeListeners()
            Log.app.warning("WebSocketOxHostTransport start failed error=\(error.localizedDescription); reopen Ox to retry")
        }
    }

    func disconnectClients() {
        for client in connections.values { client.connection.cancel() }
        connections.removeAll()
    }

    private func closeListeners() {
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
        disconnectClients()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        addressPoll?.cancel()
        addressPoll = nil
        path = nil
        ingress = nil
        closeListeners()
        Log.app.info("WebSocketOxHostTransport stopped")
    }

    private func hasCurrentIngress(_ client: Client) -> Bool {
        guard access.enabled, let path, ingress == client.ingress,
              HostTransportIngress.current(on: path) == client.ingress else { return false }
        return client.ingress.accepts(client.connection.currentPath, address: client.address, port: port)
    }

    private func accept(_ connection: NWConnection, ingress: HostTransportIngress, address: String) {
        guard access.enabled, self.ingress == ingress, !listeners.isEmpty, connections.count < 8,
              UIApplication.shared.applicationState == .active else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = Client(connection: connection, scope: StorageRoot.currentScope, ingress: ingress, address: address)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, let client = self.connections[key], client.connection === connection else { return }
                switch state {
                case .ready:
                    guard self.hasCurrentIngress(client) else { connection.cancel(); return }
                    self.receive(on: connection)
                    Log.app.info("WebSocketOxHostTransport connected mode=\(ingress.description) clients=\(self.connections.count)")
                case .failed, .cancelled: self.connections.removeValue(forKey: key)
                default: break
                }
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] _ in
            Task { @MainActor in
                guard let self, let connection, let client = self.connections[key] else { return }
                if !self.hasCurrentIngress(client) { connection.cancel() }
            }
        }
        connection.start(queue: queue)
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let error { Log.app.warning("WebSocketOxHostTransport receive failed error=\(error.localizedDescription)") }
            guard error == nil, metadata?.opcode != .close else { connection.cancel(); return }
            Task { @MainActor in
                let key = ObjectIdentifier(connection)
                guard var client = self.connections[key] else { connection.cancel(); return }
                if let data, !data.isEmpty {
                    // Website-state transfers are already bounded at 64 MiB before base64.
                    guard data.count <= 96 * 1024 * 1024, client.pending < 16 else {
                        Log.app.warning("WebSocketOxHostTransport request limit exceeded")
                        connection.cancel()
                        return
                    }
                    client.pending += 1
                    self.connections[key] = client
                    OxHostProtocol.handle(data, host: self.host, admit: {
                        guard self.connections[key] != nil,
                              UIApplication.shared.applicationState == .active,
                              self.hasCurrentIngress(client) else {
                            return "Host unavailable; verify Host access, open Ox and reconnect"
                        }
                        guard client.scope == StorageRoot.currentScope else {
                            return "Profile changed; reconnect before continuing"
                        }
                        return nil
                    }, finished: {
                        self.connections[key]?.pending -= 1
                    }) { reply in
                        self.send(reply, on: connection)
                    }
                }
                if connection.state == .ready { self.receive(on: connection) }
            }
        }
    }

    nonisolated private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { error in
                if let error { Log.app.warning("WebSocketOxHostTransport send failed error=\(error.localizedDescription)") }
            })
    }
}
