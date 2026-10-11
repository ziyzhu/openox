# Portable verification

CI requires Bun, Git, and npm, installs with the frozen lockfile, and runs:

- Static repository checks and TypeScript through the `build` skill.
- Real CLI processes against controlled Host and repository fixtures.
- Offline CLI argument/help, log pagination, and stubbed iOS runner safety checks.
- Eval case-definition validation only, without model calls.
- Service-bundle generation and resource consistency.
- Clean-install/consumer checks for the published packages.

Live-target environment variables are cleared and automatic `.env` loading is
disabled. No simulator, provider credentials, OAuth session, or publication is
needed. A green portable run does not verify live iOS or service behavior.
Checkout fixtures must include untracked files and skip working-tree deletions;
`git ls-files --cached` still lists deleted files until they are staged.

Standalone mode additionally requires platform installation tools such as curl
and tar. It builds, downloads, and installs the current platform's CLI archive,
then verifies version/help, repository validation, discovery, and conversation operations
against fixtures with no Bun or Node on PATH. GitHub checks macOS ARM64/Intel and
Linux ARM64/x64 using the same command and pins Bun 1.3.13.

Package-owned `package-check.ts` files verify release artifacts and consumers;
never publish as a test. Model evaluation follows the `evals` skill and exploratory
UI campaigns follow `gym`. Neither replaces live upgrade/auth/service verification.
Committed service/storage replay fixtures are not maintained here. Device-template
CLI E2E checks live in this skill's `apps/ios/template-cli.test.ts` and
`apps/ios/template-launch-safety.test.ts`; setup owns their schema,
launcher, and synthetic JSON. Exact predecessor inputs and website-session snapshots
remain private external files. A current logical template does not establish upgrade
compatibility; verify actual predecessor-written storage through normal startup and
second-launch stability.
