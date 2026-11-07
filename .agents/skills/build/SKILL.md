---
name: build
description: Build native apps and bundled services, regenerate schemas, and run static, type, packaging, generated-artifact and build-tool checks. Runtime protocol, storage-upgrade and provider behavior belong to the three test suites; publication belongs to release.
---

# Build

Run from the repository root after `bun install`. Executable maintenance helpers
live in `scripts/`; shared subprocess and generated-file helpers live in
`../../lib.ts`. They resolve repository paths independently of the caller's directory.

## Commands

| Command | Purpose |
| --- | --- |
| `bun run lint` | Repository source policies, resource validation, five TypeScript projects and offline eval-definition validation. |
| `bun run build` | Verify generated schemas, generate agent/service resources, and build/verify portable packages and CLI consumers. |
| `bun run test` | Existing offline build-tool/CLI-input checks and portable protocol validation. |
| `bun run ci` | Run lint, build and test with frozen dependencies, no `.env` loading and generated-resource drift checks; see [portable checks](portable.md). |
| `bun run build:host-schema` | Regenerate Host RPC JSON/Swift artifacts. |
| `bun run build:repository-schema` | Regenerate repository JSON/Swift artifacts. |
| `bun run build:provider-schema` | Regenerate provider definitions schema. |
| `bun run build:services` | Rebuild bundled services and model-action resources. |
| `bun run generate:ios` / `bun run generate:macos` | Generate Xcode projects from each app's `project.yml`; include generated iOS changes for Xcode Cloud. |
| `bun run build:macos` | Generate the native host-only project with XcodeGen and build for macOS 26+. |
| `bun run build:ios` | Build the iOS app for a generic Simulator without booting one. |
| `bun run build:agent` | Rebuild native bundles, the portable prompt renderer, package-owned bundled skills, and TS-owned `ModelGuidance.generated.swift`. |

Both native builds write the full xcodebuild log to the system temporary directory and print
only `PASS` or the unique compiler errors with the log path; read the log only when the summary
is not enough. Append xcodebuild arguments such as `-derivedDataPath <dir>` to either command.
For changes confined to `apps/shared`, `build:macos` compiles the same shared sources without
a Simulator; use it as the first compile check, then `build:ios` before iOS verification.

`lint` validates public/private-content boundaries, iOS Client-Host layering,
platform source ownership, unsafe absolute-path slicing, bundled skill packages and links,
translations, and provider models. It runs the explicit check list in `scripts/lint.ts`
against the full repository, then checks TypeScript and eval definitions without generating
or fixing files. Keep cross-file and resource checks here rather than forcing them into
per-file JavaScript lint rules. `build` checks schema consistency before generating
resources and verifying packages; native compilation remains explicit through
`build:ios` and `build:macos`. `.agents/tsconfig.json` includes test, eval, Gym, demo,
setup, build, and release code.

## Maintain generated sources

Change the owning source, regenerate with its public command, and review the
focused output diff. Do not change contract schemas merely to make checks pass;
service manifest changes require maintainer approval.

Provider definitions and discovery settings live in
`apps/shared/Host/ModelProviders/providers.json`; integration and account references
live alongside it in `references/`, starting with
[native integrations](../../../apps/shared/Host/ModelProviders/references/native-integrations.md).
New models arrive through runtime discovery; do not pin models merely because they
are new. Preserve existing picker IDs, aliases, variants, intentional token caps,
and regional/subscription boundaries. Change discovery formats, catalogs, rules,
and data-expressible options in `providers.json`; Swift owns transports, custom
adapter authentication, and OAuth. Never promote credentials, personal overrides,
or account-specific availability into bundled defaults. Run `bun run lint` and `bun run build`
after provider changes; shared Swift changes require both native builds.

`apps/shared/Resources/OxServices.bundle/` is the single built-in repository source.
Both native targets compile `apps/shared` and their own platform sources; neither compiles the other app. `lint` enforces this boundary and rejects OS conditionals in native Swift sources. Keep shared/platform Swift filenames distinct: localization extraction writes their `.stringsdata` outputs into the same target directory.
`build:services` validates it, refreshes its content hash without rewriting service
files, and generates model-action resources.
Package builds copy this source.
It is a build operation, not live service verification. Bundled installers register handlers through `window.ox.install`; the Host runtime owns dispatch and error logging. Do not replace `window.ox` or retain a second dispatcher.
Native targets default to MainActor with approachable concurrency. Use worker actors or `@concurrent` async helpers for CPU work and synchronous I/O; `nonisolated async` and inherited `Task` closures alone do not establish an off-main boundary. Publish observable state on MainActor after validating the captured scope or revision.
Do not overwrite unrelated repository or generated changes.
`PiDurable.bundle` and `ModelGuidance.generated.swift` are ignored build outputs: edit bundled packages in `packages/agent/skills/`, then run `build:agent` before native builds. The package exports normal System skill packages. Hosts receive a scoped `skillPackages` snapshot from the trusted runtime and resolve them through the normal skills catalog and filesystem. Skill activation loads workflow context; runtime permissions are independent of activation. Xcode Cloud installs the pinned Bun version and generates it in `ci_post_clone.sh`; the target rejects missing or empty runtime resources. Verify the built `.app` when changing this packaging path. Dependency upgrades also require a native launch and Mock turn: Node VM realms expose globals absent from bare JavaScriptCore, and upstream UUID generation and duration metrics need native secure-random and monotonic-clock bridges. Keep `whatwg-url` on 14.x until its newer `webidl-conversions` dependency supports runtimes without `SharedArrayBuffer`; do not substitute a fake shared-memory implementation.
For native HTML extraction dependency changes, verify byte-for-byte Markdown parity against the pinned upstream offline API across its HTML fixtures in bare JavaScriptCore, measure peak memory on nested HTML, and exercise `ox.web.fetch` through a fresh app. Keep extraction network access behind the Host fetch boundary; upstream async network extractors cannot bypass it.
The same build generates native filesystem contracts from `packages/agent/src/core/filesystem-contract.ts`, using pinned Pi read/write/edit schemas. Edit agent contracts and logic, not the generated Swift. Run `build:agent` before native compilation when changing function guidance or filesystem schemas; native compilation alone can reuse stale generated resources. Keep `packages/agent/src/functions/*/contracts.json` synchronized with a fresh Host's `ox vm functions --json`, including descriptions and required-field ordering; verify with the native VM contract runner. `execute` → `ox.fs.*` is the sole model filesystem surface; native backends retain source permissions, platform effects, and storage safety.
All hosts share one core prompt. Put presentation facts in current turn context and detailed capability guidance in function help or matching skills; avoid capability-driven prose parsing or rendered-text patching.

Run `bun run ci` after maintenance. `scripts/ci.sh` owns credential-free orchestration;
static eval-definition validation does not load API keys or invoke models. Build-only
checks live in `checks/`, not the protocol suite. Do not add general agent unit tests. Simulator provisioning
belongs to `setup`; real-model behavior belongs to `evals`; publication belongs
to `release`. Individual check implementations may be invoked directly for debugging.
Keep screenshots, traces, credentials, and diagnostics outside the repository.
