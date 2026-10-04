# Verification

Four groups: contracts, apps, packages, and evals. GitHub runs portable checks;
iOS, authentication, and real models are explicit local runs. A green portable
run is not evidence that iOS or authenticated services were exercised.

## Supported entry points

```sh
./scripts/ci.sh
./scripts/ci.sh --standalone-only --out /tmp/ox-cli-artifacts
./scripts/ios-ci.sh --device ox-1
./scripts/ios-ci.sh --device ox-1 --migration --contracts
```

Scripts resolve the checkout root themselves. Portable CI requires Bun, Git,
and npm; standalone mode additionally uses normal platform installation tools
such as curl and tar. Both install dependencies with the frozen lockfile. Use
`--help` for options. GitHub pins Bun 1.3.13.

### Portable CI

`ci.sh` runs:

1. Typecheck and repository checks: boundaries, schema consistency, model catalog,
   translations, system skills, and public/private-content checks.
2. Client-Host CLI-process contract checks against a controlled WebSocket fixture.
3. Host-Service repository/manifest/action-registration checks.
4. Offline CLI help/argument checks, log-pagination regressions, and simulator
   runner safety checks using stubbed commands.
5. Eval case-definition validation only: no model invocation.
6. Service-bundle build and generated resource consistency.
7. Clean-install/consumer checks for each published package.

Live-target environment variables are cleared, and automatic `.env` loading is
disabled for gated test/eval commands inside the script. Optional live
chat cases in the CLI file skip deliberately; actual Host contracts are not
selected. No simulator, API key, OAuth session, or publication is needed.

`ci.sh --standalone-only` builds, downloads, and installs the native CLI archive,
then checks version/help, repository inspection/validation, Host discovery, and
chat create/send/inspect against the fixture. The installed executable runs with
no Bun or Node on PATH and ignores the working directory's `.env`/`bunfig.toml`.
Locally this verifies only the current OS/architecture. GitHub uses the same
script for macOS ARM64/Intel and Linux ARM64/x64.

### Local iOS

`ios-ci.sh` requires `sim`, Xcode, and an explicitly reserved fixed-pool simulator.
Read recent sim activity and coordinate other agents before running; follow
[`AGENTS.md`](../AGENTS.md) for runtime and baseline-state requirements. It never
provisions, clones, uninstalls, erases, changes credentials, or enables Host access.

The bundle ID comes from `--bundle`, `OX_BUNDLE_ID`, or `apps/ios/Local.xcconfig`.
Enable Host connections in the reserved app first. The default endpoint uses the
selected device's assigned port. For VPN ingress, pass its reachable address:

```sh
./scripts/ios-ci.sh --device ox-1 --host ws://<simulator-vpn-address>:9101
```

The runner follows Apple's [Simulator build/launch workflow](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
through sim rather than calling xcodebuild. It force-builds/installs/launches the checkout with bundled services,
creates a temporary Mock chat, sends scenario `2`, asserts the completed reply,
and verifies a visible assistant message through sim. It leaves provider defaults
and settings alone, attempts to restore the previously selected saved chat, and
only shuts down a simulator it booted. Relaunching can discard an existing
unsaved temporary chat: use a dedicated QA target, not personal working state.

`--migration` runs existing storage fixtures through the installed Host. Use it
for persisted-storage changes, not only edits to StorageMigrator.
`--contracts` runs live read-only Client-Host checks. The destructive foreground
lifecycle case is not enabled automatically. Other targeted live checks can be
run directly after reserving their target:

```sh
OX_RPC_TEST_ENDPOINT=ws://<owned-host>:<port> bun test tests/contracts/client-host
OX_CLI_TEST_DEVICE=ox-1 bun test tests/apps/cli/chat.test.ts
bun tests/apps/cli/logs.ts --host ws://<owned-host>:<port>
```

VPN-ingress checks additionally require `OX_RPC_DENIED_ENDPOINTS`; the foreground
lifecycle case requires `OX_RPC_LIFECYCLE_DEVICE`. Do not set them for another
agent's device. iOS screenshots/build results/chat snapshots and failure diagnostics
are stored in a fresh directory outside the repository; `--output` selects its
parent. The runner's PID lock coordinates repository QA runners only, not manual
sim use or other agents.

## Targeted local QA

- `apps/ios/scenarios/` contains agent-driven UI/auth/service prompts.
- `bun run test:services --device ox-N` runs recorded service fixtures through
  the lifecycle-owning local harness. Bundled services are normal; use
  `--repository` only for explicit installation/sync verification. `--reset` is
  destructive and opt-in. Cleanup never uninstalls the app.
- `bun run sim:bootstrap --help` installs selected credentials/artifacts and can
  copy cookie/local-storage state between two reserved running devices.
- Canvas/MCP fixture helpers live in `tools/qa/fixtures/`; see their README.

Recorded service fixtures are retained. The former standalone provider-auth
runner is now a scenario prompt. Three unwired Swift assertion programs were
retired; they were not executed by CI. Shipping CLI builders/installers and
package checks remain with their owning app/package.

## Packages and evals

Each package's `package-check.ts` owns its release artifact, clean installation,
public exports, and consumer smoke checks. Do not publish packages as a test.

Real-model evals remain in [`evals/`](../evals/README.md), outside the ordinary CI
gate. Validate cases in portable CI; select a prepared Host and provider/model
explicitly for real runs. The existing fixture-agent runner remains until the
separate prompt-in/ox-driven-trace-out replacement is ready. Reports belong
outside the repository and may contain sensitive Profile context.

## Changes and evidence

Run portable CI for ordinary changes. Run local iOS build/chat checks for iOS or
chat changes; add migration checks for storage changes, live contracts for Host
changes, relevant signed-in/signed-out scenarios for auth/service changes, and
selected real-model evals for agent/prompt changes. Record commands, targets,
results, and evidence in the PR/commit; state when local checks were not run.
