import Darwin
import Foundation
import Network

/// Finds the device's locally configured Tailscale VPN, not the identity of a peer.
/// Authentication and grants are enforced by that VPN; source IPs are never credentials.
nonisolated struct TailscaleHostIngress: Equatable, Sendable {
    let interface: NWInterface
    let addresses: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.interface.index == rhs.interface.index && lhs.addresses == rhs.addresses
    }

    static func current(on path: NWPath) -> Self? {
        guard path.status == .satisfied else { return nil }
        let local = localAddresses()
        let candidates = path.availableInterfaces.compactMap { interface -> Self? in
            guard interface.type == .other, interface.name.hasPrefix("utun") else { return nil }
            let addresses = local[interface.name] ?? []
            let ipv4 = addresses.filter(isTailscaleIPv4)
            let ipv6 = addresses.filter(isTailscaleIPv6)
            // Require both Tailscale address families on one VPN, and fail closed on ambiguity.
            guard ipv4.count == 1, ipv6.count == 1 else { return nil }
            return Self(interface: interface, addresses: ipv4 + ipv6)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func accepts(_ path: NWPath?, address: String, port: NWEndpoint.Port) -> Bool {
        guard let path, path.status == .satisfied, path.usesInterfaceType(.other),
              !path.availableInterfaces.isEmpty,
              path.availableInterfaces.allSatisfy({ $0.index == interface.index }),
              case let .hostPort(host, localPort) = path.localEndpoint else { return false }
        return host == NWEndpoint.Host(address) && localPort == port
    }

    private static func isTailscaleIPv4(_ value: String) -> Bool {
        guard let bytes = IPv4Address(value)?.rawValue else { return false }
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    private static func isTailscaleIPv6(_ value: String) -> Bool {
        guard let bytes = IPv6Address(value)?.rawValue else { return false }
        return bytes.prefix(6) == Data([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    }

    private static func localAddresses() -> [String: [String]] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: [String]] = [:]
        var entry = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = current.pointee.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text,
                              socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result[String(cString: current.pointee.ifa_name), default: []].append(String(cString: text))
        }
        return result
    }
}
