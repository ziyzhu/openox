import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";

/// The device's locally configured Tailscale VPN, not the identity of a peer.
/// Authentication and grants are enforced by that VPN; source IPs are never credentials.
export type TailscaleIngress = { interfaceName: string; addresses: string[] };

const tailscaleInterfaceName: Record<string, RegExp> = {
  win32: /^Tailscale\b/i,
  linux: /^tailscale\d*$/,
  darwin: /^utun\d+$/,
};

export function tailscaleIngress(
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces(),
  platform: string = process.platform,
): TailscaleIngress | undefined {
  const name = tailscaleInterfaceName[platform];
  if (!name) return undefined;
  const candidates = Object.entries(interfaces).flatMap(([interfaceName, entries]) => {
    if (!name.test(interfaceName)) return [];
    const ipv4 = (entries ?? []).filter(entry => entry.family === "IPv4" && isTailscaleIPv4(entry.address));
    const ipv6 = (entries ?? []).filter(entry => entry.family === "IPv6" && isTailscaleIPv6(entry.address));
    // Require both Tailscale address families on one VPN, and fail closed on ambiguity.
    if (ipv4.length !== 1 || ipv6.length !== 1) return [];
    return [{ interfaceName, addresses: [ipv4[0]!.address, ipv6[0]!.address] }];
  });
  return candidates.length === 1 ? candidates[0] : undefined;
}

function isTailscaleIPv4(address: string): boolean {
  const [first, second] = address.split(".").map(Number);
  return first === 100 && second !== undefined && second >= 64 && second <= 127;
}

function isTailscaleIPv6(address: string): boolean {
  return /^fd7a:115c:a1e0:/i.test(address);
}
