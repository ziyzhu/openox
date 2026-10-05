import type { TransportState } from "./host/transport.ts";

type Description = { implementation: { name: string; version: string; build: string }; protocols?: { rpc?: number[]; repository: number[] } };
declare global {
  interface Window {
    ox: {
      rpc(text: string): Promise<{ result?: unknown; error?: { message: string } } | undefined>;
      transport(): Promise<TransportState>;
      onTransport(listener: (state: TransportState) => void): void;
    };
  }
}

const text = (id: string, value: string) => { document.getElementById(id)!.textContent = value; };

function showTransport(state: TransportState): void {
  text("transport", state.status === "listening"
    ? state.ingress.addresses.map(address => `ws://${address.includes(":") ? `[${address}]` : address}:${state.port}`).join(", ")
    : "Waiting for Tailscale. Remote Clients connect only over Tailscale.");
}

const response = await window.ox.rpc(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "host.describe" }));
if (response?.result) {
  const { implementation, protocols } = response.result as Description;
  text("implementation", `${implementation.name} ${implementation.version} (${implementation.build})`);
  text("protocols", `RPC ${protocols?.rpc?.join(", ") ?? "—"} · repository ${protocols?.repository.join(", ") ?? "—"}`);
} else text("implementation", response?.error?.message ?? "Host unavailable");
showTransport(await window.ox.transport());
window.ox.onTransport(showTransport);
