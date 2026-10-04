# Repository tools

Development scripts for building generated artifacts, validating the repository,
and exercising Ox. Run these from the repository root after `bun install`.
These are not runtime app modules. Shared helpers live in `lib.ts`; numbered
simulator ports and argument parsing live in `qa-config.ts`.

## Builds and checks

| Command | Script | Effect |
| --- | --- | --- |
| `bun run typecheck` | `typecheck.ts` | Run repository checks and typecheck six TypeScript projects. Read-only. |
| `bun run build:host-schema` | `host-rpc-contract.ts` | Write Host RPC JSON schemas and Swift request definitions. |
| `bun run check:host-schema` | `host-rpc-contract.ts` | Check generated Host RPC artifacts without writing. |
| `bun run build:repository-schema` | `repository-contract.ts` | Write repository schema and iOS supported-version definitions. |
| `bun run check:repository-schema` | `repository-contract.ts` | Check generated repository artifacts without writing. |
| `bun run build:provider-schema` | `provider-definitions.ts` | Write model-provider schema. |
| `bun run update:llms` | `provider-models.ts` | Update the provider model catalog; requires network access. |
| `bun run build:services` | `ios-services-build.ts` | Rebuild the iOS service bundle, Local Git seed, and model-action resources. Requires Git. |
| `bun run check:localizations` | `localization-check.ts` | Validate translation catalogs. Read-only. |
| `bun run check:system-skills` | `system-skills-check.ts` | Validate bundled system skills. Read-only. |
| `bun run check:public-boundary` | `public-boundary-check.ts` | Scan tracked/unignored files for private content and secrets. Read-only. |

`ios-host-contract-check.ts` validates Client/Host boundaries as part of
`typecheck`. Generated-file helpers resolve paths against the repository root,
including when a generator is invoked by absolute path from another directory.

## Service replay: reserve first, reset explicitly

Requires `sim`, Xcode, and a provisioned five-device QA pool. Follow the simulator
ownership, recent-activity, and common-state rules in [`AGENTS.md`](../AGENTS.md)
before running. `ox-1` through `ox-3` must use iOS 26; `ox-4` and `ox-5` must use
iOS 27. Replay never creates or clones a missing device.

```sh
# Bundled services on a simulator you have reserved:
bun run test:services --device ox-3

# One recorded case:
bun run test:services github.com:action:case --device ox-3

# Explicit repository installation/sync verification:
bun run test:services --repository examples/repository --device ox-3

# Destructive fresh-app run, only on a reserved device whose data may be deleted:
bun run test:services --device ox-3 --reset
```

- `--device` is required explicitly; there is no default, and `OX_QA_DEVICE`
  alone is insufficient.
- By default, replay does not uninstall the app. `--reset` attempts to uninstall
  it **before** replay, deleting its local app data; it does not erase the device
  or reset its keychain. Reestablish baseline state afterward if needed.
- Replay builds, reinstalls, and launches the Debug app, marks onboarding complete,
  disables iCloud for the run, configures replay endpoints, and executes fixtures.
  It is not a read-only operation and can change app data even without `--reset`.
- Cleanup never uninstalls the app. An already-booted device stays booted; only a
  device booted by this invocation is shut down. Preflight failures do not mutate
  simulator state. Failed launch/replay attempts collect simulator diagnostics.
- A temporary PID lock prevents concurrent **service-replay invocations** on the
  same device. It does not detect other agents or manual simulator use; reserve
  ownership separately. The lock is released during cleanup.
- Bundled services are the default. Only `--repository` (or `OX_SERVER_ROOT`)
  starts a temporary loopback repository server and verifies `/health`.

## Other simulator QA

| Script / command | Prerequisites and side effects |
| --- | --- |
| `bun run sim:bootstrap --help` | Running Debug Host. Installs provider keys/artifacts and optionally restores website state; read help and reserve source and target first. |
| `bun run test:storage-migration` | Running Debug Host and migration fixtures. Exercises persisted-storage migration; use only a reserved QA device. |
| `bun tools/canvas-integration-fixture.ts --device ox-N` | Starts local repository/fixture servers. Follow [`fixtures/README.md`](fixtures/README.md) for proxy and simulator setup. |
| `bun tools/model-provider-auth-qa.ts --device ox-N` | Running Debug Host with Doubao signed out. Drives UI/chat/auth flows and captures diagnostics outside the repository. |

Never print provider keys or commit screenshots, traces, credentials, or
simulator diagnostics. Keep temporary evidence outside the repository.

## Tests and publishing

`bun run test:e2e` runs `tests/`: CLI/repository checks, service-replay subprocess
lifecycle checks with a stubbed `sim`, and opt-in live Host checks. Live checks
require their documented endpoint/device environment variables; otherwise they
are skipped. Consult [`packages/protocol/README.md`](../packages/protocol/README.md)
and the test files before selecting a live target.

`npm-publish.ts` is invoked by the npm publishing workflow. It validates and
publishes a supplied package tarball; `--dry-run` suppresses publication but still
queries npm. Do not run it as a validation step; inspect the script and workflow
before an authorized release.
