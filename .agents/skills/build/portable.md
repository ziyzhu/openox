# Portable verification

CI installs with the frozen lockfile and runs build/static checks, controlled CLI/Host
fixtures, offline build-tool safety checks, eval-definition validation,
service generation, and package consumer checks. It clears live-target variables and
disables `.env` loading. No simulator, credentials, model calls, or publication are required.

The GitHub CI workflow also compiles the iOS and macOS apps unsigned on a macOS runner.
It catches Swift build breaks only; it does not launch or exercise either app.

Standalone mode additionally needs platform installation tools such as curl and tar.
It installs the current platform's CLI archive and exercises fixtures without Bun or
Node on PATH. See the CI workflow for platform coverage and pinned tool versions.

Checkout fixtures must include untracked files and skip working-tree deletions;
`git ls-files --cached` includes deleted files until staged. Package-owned
`package-check.ts` files verify release consumers; never publish as a test.
Device-template checks live in this skill's `checks/ios/template-*.test.ts`; `setup`
owns the schema and launcher. Predecessor storage and website-session evidence remain
private external files. Portable checks do not establish live upgrade, auth, or service coverage.

CLI help checks should assert public flag names and value arity in the Flags section,
not placeholder wording. Verify argument behavior through real CLI processes; keep
package expectations independent of the help renderer so missing flags still fail.
