import { parseArgs } from "node:util";
import { WindowsHost } from "./host.ts";
import { defaultPort } from "./transport.ts";

// Headless Host for development: the same Host the desktop app embeds, without the Client UI.
const { values } = parseArgs({ options: { port: { type: "string" } } });
const port = Number(values.port ?? defaultPort);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("--port must be between 1 and 65535");
const host = new WindowsHost(port);
host.start();
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => { host.stop(); process.exit(0); });
