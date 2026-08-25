# Service Repositories

Ox resolves services from four repository provenances: Bundled, Remote,
Development, and Local. Bundled ships in the iOS app, Remote repositories are
installed from public git URLs, Development is supplied by the simulator's Ox
Server, and Local is stored on-device for authoring. Every repository has a
`repository.json` file at its root. The file is an explicit inventory; Ox does not
discover services by scanning folders.

```json
{
  "version": 1,
  "name": "Example Services",
  "contentHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "services": [
    "web:example.com"
  ]
}
```

`version`, `name`, and `services` are required. The SHA-256 `contentHash` is
optional. A repository can list at most 256 services. Every service ID is
exactly `<kind>:<identity>`, where kind is `web`,
`ios`, or `mcp`. Service identities must be unique across all kinds. Ox derives
the service directory by replacing the first colon with a slash, so
`web:example.com` resolves to `web/example.com` and `ios:browser` resolves to
`ios/browser`.

Web services contain `service.json` and `actions.js`. Their optional
`faviconUrl` is an absolute public HTTPS URL; favicon image files are not part of
the generated repository or app bundle. Ox's built-in web icons use stable
`https://openox.ai/assets/services/<domain>/favicon.png` URLs served by CloudFront
from a private S3 bucket. MCP services contain `service.json`. Native iOS
services can appear only in the built-in repository; an external repository that
lists one is rejected. Existing source service manifest schemas are unchanged.

Current writers emit `repository.json` and `service.json`. Readers also accept
the legacy `ox.json` and `manifest.json` filenames so existing repositories can
be opened and republished in the current layout.

Built-in authoring sources live in `repositories/builtin/`. `bun run build:services`
compiles their runtime artifacts into the committed
`apps/ios/OpenOx/Resources/OxServices.bundle`. A complete standalone remote repository example
lives in `examples/service-repository/`.

Ox accepts additional repositories only through public HTTPS URLs without
embedded credentials. It clones into staging, validates the repository, removes
`.git`, and atomically replaces the installed `HEAD` snapshot. Symbolic links and
oversized services are rejected, and a failed update preserves the last valid
snapshot. Development uses the same snapshot transaction. Bundled is read
directly from the signed app.

Only Local owns Git state. It is initialized with an empty repository commit and
records authoring changes on-device. Existing commits, index state, and working
tree changes are never replaced. Local descriptors expose the active
`commitHash`, the `tipCommitHash`, and whether the working view is `live` or
`historical`.

Ox merges enabled repositories into a `MonoRepository`. It contains the
selected manifest for every service identity plus a deterministic hash of those
selections. The hash advances when the effective merged repository changes; it
is not a Git commit.

All enabled repositories contribute candidates to the `MonoRepository`. When
more than one repository provides the same identity, Ox selects the Bundled
implementation by default and shows the conflict in Settings. The user selects
one complete implementation; files are never merged between repositories.
Local always exists and is always enabled. Creating or copying a service into
Local selects the Local candidate.

Bundled, Remote, and Development repositories are read-only. Local is editable,
but its source does not create a separate virtual mount: every selected service
still resolves at `services/<kind>/<id>/`. Read-only services expose only
`service.json`; Local services expose their additional source files and accept
validated `ox.fs` writes, edits, and deletes. Those mutations do not reload a
running attachment. Calling `ox.service.attach` attaches a missing service or
replaces that chat's existing attachment from the current source, allowing
several coherent edits to be tested together without requiring a commit.

Agents inspect Local through `ox.service.git.status`, `diff`, `log`, and `show`.
Diff reviews the current working tree, one commit against its parent, or two
commits without changing the active view. `checkout` temporarily visits a commit
without moving `main`; a historical view is read-only until `checkout` receives
`commitHash: "latest"`. Local also supports `commit`, `revert`, and `restore`.
Revert creates a new inverse commit. Restore erases every staged, unstaged, and
untracked Local change. There are no branch, merge, rebase, rollback, push, or
Git operations on other repositories.
