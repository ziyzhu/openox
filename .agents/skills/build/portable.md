# Portable verification

CI installs with the frozen lockfile, then runs `lint`, `build`, and `test`.
These cover static/type checks, agent/service generation, package consumers,
offline build-tool safety checks, and shipped bundles. CI clears live-target
variables and disables `.env` loading.
No simulator, credentials, real model calls, or publication are required.

Run `bun run ci --native` on macOS for portable checks, the current platform's
standalone CLI checks and unsigned iOS/macOS builds. Xcode and XcodeGen must be
installed. `.bun-version` owns the required Bun version; `.github/ci.json` owns
Node/npm requirements, the Xcode version, CLI runner matrix, and fallback iOS bundle
identifier. CI validates applicable requirements before installing dependencies;
select Xcode with `DEVELOPER_DIR` or `xcode-select`. Run the same checks on another
machine for other platforms; no machines
or VMs are provisioned locally.

`scripts/ci.sh` maps each command to one environment and an ordered list of steps.
`scripts/ci-environment.ts` validates environment prerequisites; the step dispatcher
runs existing commands sequentially and stops on the first failure. Logs identify
the workflow, environment, and current step. Workflow definitions do not provision
machines or resolve dependency graphs. A preflight failure is reported as `BLOCKED`;
a failing execution step is reported as `FAIL`, with its original nonzero exit code.

Native verification disables signing and clears the development team through
command-line build settings, without rewriting existing local configuration. It
keeps the configured iOS bundle identifier. If `Local.xcconfig` is absent, CI creates
one with the shared fallback identifier and removes it on exit. It does not boot a
simulator or publish anything.

Use `bun run ci --ios-only` or `bun run ci --macos-only` for one native target with
the same preflight, frozen install, agent generation, and unsigned build settings.
These modes are mutually exclusive with other CI modes; `--out` remains standalone-only.
The macOS-only mode does not create or modify iOS configuration.

The GitHub CI workflow runs `--ios-only` and `--macos-only` in parallel matrix jobs.
Relevant initial pushes to `main` prepare
the signed IPA alongside validation; TestFlight upload waits for both targets,
portable checks, and IPA preparation to pass. Main CI and manual iOS releases share
a serialization group to protect build-number selection. The four-platform CLI
matrix runs separately. Native builds do not launch or exercise either app.

Standalone mode additionally needs platform installation tools such as curl and tar.
It installs the current platform's CLI archive and exercises fixtures without Bun or
Node on PATH. GitHub reads its platform matrix from `.github/ci.json`; local CLI
checks validate only the current platform, not the entire matrix.

Checkout fixtures must include untracked files and skip working-tree deletions;
`git ls-files --cached` includes deleted files until staged. Package-owned
`package-check.ts` files verify release consumers; never publish as a test.
Device-template checks live in this skill's `checks/ios/template-*.test.ts`; `setup`
owns the schema and launcher. Predecessor storage and website-session evidence remain
private external files. Portable checks do not establish live upgrade, auth, or service coverage.

CLI help checks should assert public flag names and value arity in the Flags section,
not placeholder wording. Verify argument behavior through real CLI processes; keep
package expectations independent of the help renderer so missing flags still fail.
