import { RPC_VERSION } from "../../../../packages/protocol/src/index.ts";
import { REPOSITORY_VERSIONS } from "../../../../packages/protocol/src/repository.ts";
import packageMetadata from "../../package.json";
import type { Handlers } from "./rpc.ts";
import { defaultPort, WebSocketHostTransport, type TransportState } from "./transport.ts";

/// The Windows Ox Host. Methods are advertised only once implemented; see apps/windows/README.md.
export class WindowsHost {
  readonly handlers: Handlers = {
    "host.describe": async () => this.describe(),
  };
  private readonly transport: WebSocketHostTransport;

  constructor(port = defaultPort, onTransportChange?: (state: TransportState) => void) {
    this.transport = new WebSocketHostTransport(this.handlers, port, onTransportChange);
  }

  describe() {
    return {
      implementation: { name: "Ox for Windows", version: packageMetadata.version, build: process.env.OX_BUILD ?? "development" },
      protocols: { rpc: [RPC_VERSION], repository: [...REPOSITORY_VERSIONS] },
      methods: Object.keys(this.handlers),
    };
  }

  start(): void { this.transport.start(); }
  stop(): void { this.transport.stop(); }
}
