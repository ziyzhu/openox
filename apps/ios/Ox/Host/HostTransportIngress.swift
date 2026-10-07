import Foundation
import Network

nonisolated enum HostTransportIngress: Equatable, Sendable {
    case tailscale(TailscaleHostIngress)
    #if DEBUG && targetEnvironment(simulator)
    case loopback
    #endif

    static var loopbackEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["OX_HOST_LOOPBACK"] == "1"
        #else
        false
        #endif
    }

    static func pathMonitor() -> NWPathMonitor {
        loopbackEnabled ? NWPathMonitor() : NWPathMonitor(requiredInterfaceType: .other)
    }

    static func current(on path: NWPath) -> Self? {
        #if DEBUG && targetEnvironment(simulator)
        if loopbackEnabled { return .loopback }
        #endif
        return TailscaleHostIngress.current(on: path).map(Self.tailscale)
    }

    var description: String {
        switch self {
        case .tailscale(let ingress): "tailscale interface=\(ingress.interface.name)"
        #if DEBUG && targetEnvironment(simulator)
        case .loopback: "debug-simulator-loopback"
        #endif
        }
    }

    var addresses: [String] {
        switch self {
        case .tailscale(let ingress): ingress.addresses
        #if DEBUG && targetEnvironment(simulator)
        case .loopback: ["127.0.0.1"]
        #endif
        }
    }

    func constrain(_ parameters: NWParameters) {
        switch self {
        case .tailscale(let ingress): parameters.requiredInterface = ingress.interface
        #if DEBUG && targetEnvironment(simulator)
        case .loopback: parameters.requiredInterfaceType = .loopback
        #endif
        }
    }

    func accepts(_ path: NWPath?, address: String, port: NWEndpoint.Port) -> Bool {
        switch self {
        case .tailscale(let ingress):
            ingress.accepts(path, address: address, port: port)
        #if DEBUG && targetEnvironment(simulator)
        case .loopback:
            if let path, path.status == .satisfied, path.usesInterfaceType(.loopback), address == "127.0.0.1",
               case let .hostPort(localHost, localPort) = path.localEndpoint,
               case let .hostPort(remoteHost, _) = path.remoteEndpoint {
                localHost == NWEndpoint.Host(address) && localPort == port && remoteHost == NWEndpoint.Host(address)
            } else {
                false
            }
        #endif
        }
    }
}
