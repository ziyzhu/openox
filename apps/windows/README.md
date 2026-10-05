# Ox for Windows

**Preview scaffold.** Ox for Windows is a desktop Ox Client with an embedded Ox
Host, built with Electron and TypeScript. It reuses `@openox/protocol` today and
is planned to reuse `@openox/services` and `@openox/agent`. It cannot hold chats
yet. The roadmap and design decisions are in
[`assets/WINDOWS.md`](../../assets/WINDOWS.md).

What works today:

- An Electron window with the Ox Client shell, styled from [`DESIGN.md`](../../DESIGN.md).
- An embedded Host that answers `host.describe` with the shared contract
  validation. The desktop Client calls it over IPC with the same JSON-RPC
  handlers that remote Clients use.
- Remote Clients, such as the [Ox CLI](../cli/README.md), on Tailscale only.
  The ingress rules match iOS: the listener binds only to the local Tailscale
  adapter, which must have exactly one `100.64.0.0/10` address and one
  `fd7a:115c:a1e0::/48` address. A missing or ambiguous adapter disables
  networking. Browser `Origin` handshakes are rejected.

## Run

This package is outside the root Bun workspaces, so Electron is not installed
into the repository's CI. Install the root workspace first, then this app:

```sh
bun install                      # repository root
cd apps/windows
bun install
bun run start                    # build and launch the desktop app
bun run host                     # headless Host only, for CLI development
bun run typecheck
```

If `bun install` skips Electron's binary download, run
`node node_modules/electron/install.js`.

With Tailscale connected, connect from another tailnet device:

```sh
ox --host ws://<windows-machine>.<tailnet>.ts.net:9876 host describe
```

`--port` changes the headless Host's port. It cannot change the interface.

## Layout

- `src/host/`: the platform-neutral Host (ingress, transport, JSON-RPC dispatch, `WindowsHost`).
- `src/main.ts`: Electron main process. It owns the window and the embedded Host.
- `src/preload.ts`: sandboxed bridge that exposes `window.ox.rpc` to the Client.
- `src/renderer.ts`, `renderer/`: the Client UI.
