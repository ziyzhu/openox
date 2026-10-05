# Ox for Windows plan

## Status and goal

This is a proposal. Maintainers have not approved it yet. The goal is a native
Windows Ox: a desktop Client with an embedded Host. It should hold the same
three promises as iOS:

1. **Connect anything**
2. **Local first**
3. **Yours**

It should also be reachable from other Clients over Tailscale, as the iOS Host is.

Already done:

- The standalone CLI Client ships for Windows x64 and ARM64. It is installed with
  `apps/cli/install.ps1`.
- The [`apps/windows`](../apps/windows/README.md) scaffold runs an Electron shell
  with an embedded Host. The Host answers `host.describe` with iOS-equivalent
  Tailscale ingress.

Everything below is the remaining roadmap.

## Decision: Electron and TypeScript

The iOS Host is about 59k lines of Swift. Most of the portable logic already has
a TypeScript counterpart in this repository:

- `@openox/protocol`: contracts and validation
- `@openox/services`: the built-in repository and skills
- `@openox/agent`: the host-neutral Pi Durable session
- pi-ai: provider transports and OAuth
- the CLI: Profile and repository readers, and an RPC client

`assets/PI_DURABLE.md` already plans for non-iOS hosts that reuse
`@openox/agent` through their own adapters.

| Option | Reuses TS packages | Website services | Verdict |
| --- | --- | --- | --- |
| **Electron** | Directly, in the main process | Chromium `session`/`webContents`: persistent partitions, document-start scripts, `executeJavaScript` awaits promises | **Chosen** |
| Tauri + WebView2 | Only through a Node or Bun sidecar | WebView2 lacks promise-awaiting script execution without CDP | Smaller binary, but two runtimes |
| WinUI 3 / .NET | No | WebView2, same gaps | Full rewrite |

Electron costs about 100 MB of install size. In exchange, the Host, the Client
and the website layer share one process model.

## Architecture

```text
Renderer (Client UI, sandboxed) ── IPC: JSON-RPC ──┐
Remote Clients (ox CLI, iOS?) ── WebSocket on Tailscale ──┤
                                                   ▼
Electron main: WindowsHost ── handlers validated by @openox/protocol
   ├── @openox/agent (Pi Durable) + better-sqlite3 ── Profile folder
   ├── pi-ai model providers ── credentials via safeStorage (DPAPI)
   ├── VM: isolated-vm isolate running the ox.* bridge and api: actions.js
   ├── Website services: persist:ox-web session, hidden webContents
   └── Repositories: @openox/services + isomorphic-git
```

The desktop Client and remote Clients use the same handlers, so every UI
capability is also an RPC capability. One difference from iOS: there, the
SwiftUI Client reads Host objects directly.

## Subsystem mapping

| iOS subsystem | Windows replacement | Reuse | Size |
| --- | --- | --- | --- |
| RPC and Tailscale ingress | `ws` bound to the Tailscale adapter (done) | `@openox/protocol` | S |
| Agent loop (Swift `Agent`/`Chat`) | `@openox/agent` with better-sqlite3; port `ChatPromptComposer`, the `execute` tool and approvals | Pi Durable core | L |
| Model providers (22, five transports) | pi-ai transports and OAuth, mapped from `provider-models.json` | Catalog, schema, generator | S–M |
| VM (JavaScriptCore) | `isolated-vm`: real CPU and memory limits; lift the JS prelude | `ox.*` help and validator JS | M |
| `ox.*` bridge (`Chats/Functions`) | TypeScript port, namespace by namespace | — | L |
| Website services (WebKit) | Electron session partition, `ServiceActionRuntime.js` and `actions.js` injection | All `actions.js`, defuddle, turndown | L |
| API and MCP services | Port the small API runner; `@modelcontextprotocol/sdk` | Manifests | M |
| Repositories and search (SwiftGitX, NaturalLanguage) | isomorphic-git; lexical search | `@openox/services`, CLI verifier | M |
| Native `ios:*` services | WinRT equivalents or none | — | L, optional |
| Profile storage (iCloud, Keychain, UserDefaults) | Plain folder under `%APPDATA%\Ox`, settings JSON, `safeStorage` | CLI Profile reader | M |
| Canvas artifacts | Sandboxed `<webview>` with a narrow IPC bridge | `CanvasSDK.js` | S |
| Client UI (about 26k lines of SwiftUI) | Web UI in the renderer | `DESIGN.md` tokens | XL |
| Background tasks, notifications, speech, OCR, share extension | Tray process, toasts, `Windows.Media`, Share target | — | M |

## Decisions that need maintainer approval

1. **Profile format.** Windows has no legacy data. It could start on the
   Pi-first layout (`profile.json`, `state.sqlite`, `artifacts/`) instead of
   `chats/<uuid>/turns.jsonl`. Moving Profiles between iOS and Windows would
   then wait for the Pi Profile export and import that `PI_DURABLE.md` plans.
   Any compatibility code stays behind the `StorageMigrator` equivalent.
2. **Agent harness.** Windows would be the first Host where Pi Durable is the
   only harness. It cannot ship until Pi reaches parity on approvals, steering,
   compaction, services and subagents.
3. **Native service kind.** Calendar, contacts and notifications on Windows
   need a `windows:` service kind or a platform-neutral one. Either way it
   changes the service manifest schema, so it needs approval.
4. **OAuth apps.** Provider and service OAuth must use client registrations
   that belong to OpenOx. Embedded webviews are blocked by Google, so OAuth uses
   the system browser with a loopback redirect.
5. **Remote UI contract.** Today's RPC uses bounded snapshot polling. A full
   remote desktop Client would need a streaming or event contract. The embedded
   Client does not need one.

## Milestones

Each milestone ends with an E2E check, driven through the `ox` CLI and the
Electron app. No unit tests are added.

1. **M0, scaffold (done):** CLI on Windows. The Electron shell and Host answer
   `host.describe` over Tailscale and IPC.
2. **M1, models and chat:**
   - Profile folder, settings and `safeStorage` credentials.
   - pi-ai providers, starting with the API-key ones.
   - `@openox/agent` session.
   - `chats.new`, `chats.send`, `chats.get` and `chats.list`.
   - Exit check: a Mock-provider chat round trip from the CLI and from the UI.
3. **M2, VM and `execute`:**
   - `isolated-vm` runtime.
   - `ox.output`, `ox.fs`, `ox.artifact`, `ox.web.fetch` (with iOS limits), and `ox.user` approvals.
   - `vm.*` methods.
4. **M3, services:**
   - Repository install and sync.
   - API and MCP services.
   - Website services in a persistent session, with interactive sign-in.
   - `services.*` methods.
5. **M4, Client parity:**
   - Chat transcript, Markdown, composer, attachments.
   - Model picker, provider settings, Library, Services explorer, onboarding.
6. **M5, Windows integration:** tray residency and scheduled skills, toasts,
   Share target, speech and OCR.
7. **M6, release:**
   - electron-builder NSIS and MSIX for x64 and ARM64.
   - Code signing and auto-update.
   - Windows runners in CI.

## Security baseline

- **Renderer:** `contextIsolation`, `sandbox`, no `nodeIntegration`, a strict
  CSP, navigation and `window.open` denied, and links opened in the system
  browser.
- **Host networking:** Tailscale ingress only, browser `Origin` rejected, and
  the iOS limits on clients, pending requests and message size.
- **VM:** model-written code runs in a separate V8 isolate with time and memory
  limits, never in Node's `vm`.
- **Website data:** confined to one persistent partition. Sign-out clears it by
  registrable domain.
- **Logs:** structured, user-owned diagnostics. They never contain credentials,
  message text or website data.
