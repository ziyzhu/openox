# iOS runtime dependency checks

Run `bun run build:agent` before native builds. After upgrading a runtime dependency, launch the native app and run a Mock turn: Node VM realms expose globals absent from bare JavaScriptCore, and upstream UUID generation and duration metrics need native secure-random and monotonic-clock bridges.

Keep `whatwg-url` on 14.x until its newer `webidl-conversions` supports runtimes without `SharedArrayBuffer`. Do not substitute a fake shared-memory implementation.

For HTML extraction upgrades, verify byte-for-byte Markdown parity against the pinned upstream offline API on its HTML fixtures in bare JavaScriptCore, measure peak memory on nested HTML, and exercise `ox.web.fetch` through a fresh app. LinkeDOM’s generated entity tables require `atob`; the extraction context supplies it through `Uint8Array.fromBase64`, not Node’s `Buffer`. Keep extraction network access behind Ox fetch boundary.
