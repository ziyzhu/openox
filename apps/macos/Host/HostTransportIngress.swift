import Foundation
import Network

nonisolated enum HostTransportIngress: Equatable, Sendable {
    case tailscale(TailscaleHostIngress)
    #if DEBUG
    case loopback
    #endif

    static var loopbackEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OX_HOST_LOOPBACK"] == "1"
        #else
        false
        #endif
    }

    static func pathMonitor() -> NWPathMonitor {
        loopbackEnabled ? NWPathMonitor() : NWPathMonitor(requiredInterfaceType: .other)
    }

    static func current(on path: NWPath) -> Self? {
        #if DEBUG
        if loopbackEnabled { return .loopback }
        #endif
        return TailscaleHostIngress.current(on: path).map(Self.tailscale)
    }

    var description: String {
        switch self {
        case .tailscale(let ingress): "tailscale interface=\(ingress.interface.name)"
        #if DEBUG
        case .loopback: "debug-loopback"
        #endif
        }
    }

    var addresses: [String] {
        switch self {
        case .tailscale(let ingress): ingress.addresses
        #if DEBUG
        case .loopback: ["127.0.0.1"]
        #endif
        }
    }

    func constrain(_ parameters: NWParameters) {
        switch self {
        case .tailscale(let ingress): parameters.requiredInterface = ingress.interface
        #if DEBUG
        case .loopback: parameters.requiredInterfaceType = .loopback
        #endif
        }
    }

    func accepts(_ path: NWPath?, address: String, port: NWEndpoint.Port) -> Bool {
        switch self {
        case .tailscale(let ingress):
            ingress.accepts(path, address: address, port: port)
        #if DEBUG
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
