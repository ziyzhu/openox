import type { IncomingMessage } from "node:http";
import { WebSocketServer } from "ws";
import { tailscaleIngress, type TailscaleIngress } from "./ingress.ts";
import { log } from "./log.ts";
import { handleRPC, type Handlers } from "./rpc.ts";

export const defaultPort = 9876;
const maximumMessageBytes = 96 * 1024 * 1024;
const ingressPollMs = 5000;

export type TransportState = { status: "waiting" } | { status: "listening"; ingress: TailscaleIngress; port: number };

/// Serves JSON-RPC over WebSocket only on the local Tailscale VPN. There is no LAN or loopback fallback.
export class WebSocketHostTransport {
  private servers: WebSocketServer[] = [];
  private ingress: TailscaleIngress | undefined;
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(
    private readonly handlers: Handlers,
    private readonly port = defaultPort,
    private readonly onChange: (state: TransportState) => void = () => {},
  ) {}

  start(): void {
    log("info", "WebSocketHostTransport waiting for Tailscale", { port: this.port });
    this.refresh();
    this.timer = setInterval(() => this.refresh(), ingressPollMs);
  }

  stop(): void {
    clearInterval(this.timer);
    this.close();
    this.ingress = undefined;
  }

  private refresh(): void {
    const next = tailscaleIngress();
    if (JSON.stringify(next) === JSON.stringify(this.ingress)) return;
    this.close();
    this.ingress = next;
    if (!next) {
      log("info", "WebSocketHostTransport unavailable: Tailscale ingress lost or ambiguous");
      this.onChange({ status: "waiting" });
      return;
    }
    this.servers = next.addresses.map(address => this.listen(address, next));
    this.onChange({ status: "listening", ingress: next, port: this.port });
  }

  private listen(address: string, ingress: TailscaleIngress): WebSocketServer {
    const server = new WebSocketServer({
      host: address, port: this.port, maxPayload: maximumMessageBytes,
      // CLI/native Clients omit Origin. Do not let a website use a trusted node's access.
      verifyClient: ({ req }: { req: IncomingMessage }) => {
        const browser = req.headers.origin !== undefined;
        if (browser) log("warning", "WebSocketHostTransport rejected browser origin");
        return !browser;
      },
    });
    server.on("listening", () => log("info", "WebSocketHostTransport ready", { interface: ingress.interfaceName, address, port: this.port }));
    server.on("error", error => {
      log("warning", "WebSocketHostTransport failed", { address, error: error.message });
      this.close();
    });
    server.on("connection", socket => socket.on("message", async data => {
      const response = await handleRPC(data.toString(), this.handlers);
      if (response !== undefined) socket.send(JSON.stringify(response));
    }));
    return server;
  }

  private close(): void {
    for (const server of this.servers) {
      for (const client of server.clients) client.close();
      server.close();
    }
    this.servers = [];
  }
}
