# Device templates

`bun run sim:launch --device ox-N --template <json>` builds, installs, and launches
with declarative on-device data. `--app <Ox.app>` reuses a matching Debug Simulator
artifact; `bun run sim:bootstrap --device ox-N --template <json>` applies to the
installed artifact and relaunches it. Reserve the target first. Setup uses a local
startup file, not Allow Connections or a model call; Release and physical builds cannot
apply templates. `--loopback` only opts into Debug localhost ingress and does not
turn on Allow Connections; `settings.allowConnections` sets it on the selected Profile, or the startup Profile without a selection.

The TypeScript contract is [`scripts/template-schema.ts`](../scripts/template-schema.ts); [`templates/basic.json`](../templates/basic.json)
is a runnable example. `--schema` prints JSON Schema directly from that contract.
`--validate --template <json>` checks references and external
inputs without a simulator. Omitted fields remain unchanged. Profiles get a
run-owned name suffix; each application creates new Profiles rather than merging
into existing data. Result manifests map template-local Profile/conversation IDs to actual
IDs.

For manual Simulator preference edits, stop the app and target the current data
container’s `Library/Preferences/<bundle-id>` path with `defaults`; a bare bundle
domain can address different preferences. Re-resolve the container after installation
and verify the preference in the app’s startup logs.

UserDefaults supports strings, booleans, numbers, arrays, `{ "dictionary": {...} }`,
`{ "data": "<base64>" }`, and `{ "date": "<UTC ISO timestamp>" }`; explicit `remove`
clears keys. Typed settings and raw preferences cannot conflict. Profile files can
populate nested skills as well as shared content; conversation files own attachment bytes.
Messages support user text/attachments and assistant text/reasoning; `packageFrom`
imports an existing `.conversation` package instead of `messages` for richer historical tool
results and presentation. Neither path runs historical tools or calls a model.

Credentials use `secret: { "env": "NAME" }` or `secret: { "fromFile": "path" }`;
paths resolve relative to the template JSON. `--allow-keychain` authorizes declared
writes/replacements. Named secrets require private flat JSON string-field objects;
provider credentials use the normal binding owner. `removeProviders`, `removeSecrets`,
and `removeAccounts` explicitly clear declared credentials under the same authorization.
Raw OAuth/Secret accounts and
explicit bindings support exact credential state. Never put credentials in tracked
JSON or pass their values as arguments.

`bun run sim:website-export --device ox-N --output /private/path/session.snapshot`
captures cookies/local storage from an already reachable authorized Profile. A template
can restore `websiteState: { "restoreFrom": "/private/path/session.snapshot" }`.
Restoration replaces those app-wide data types, leaves IndexedDB unchanged, and does
not prove authentication: verify required websites after restoring. Sessions can
expire or be device-bound. Snapshot files are credential-bearing, mode 0600, and
must remain outside Git.

`storage` entries name `documents`, `applicationSupport`, `appGroup`, or `caches`,
a domain-relative destination `path`, external source `from`, and `provenance`
(`build`, `storageVersion`). `--allow-storage-replay` explicitly authorizes replacing
these paths while the app is stopped, retaining prior contents in private evidence.
It also gates raw active-Profile/Secret-index preferences. This covers exact Profile,
repository, schedule, share-inbox, and temporary-cache representations without new
migrators. Logs, template control paths, overlapping sources/destinations, and linked inputs
are rejected. Snapshot inputs are streamed and hashed; restored bytes are verified
before launch. Limits are 512 MiB/100,000 entries per input and 1 GiB total. Predecessor evidence must come from the actual older build; provenance
labels alone are not proof. Normal startup still runs `StorageMigrator`; never erase
or uninstall as upgrade setup. Device-bound bookmarks and OS permissions still
require provisioning. For a registered Profile, replay each immediate child (including `.ox`) as a separate storage entry, never the Profile root itself: replacing that directory invalidates its bookmark even at the same path. Unknown template fields fail rather than being ignored.

Evidence includes a redacted manifest, original changed preferences, storage backups,
AX tree, screenshot, and fresh logs outside the repository. Credential-bearing input
is deleted after loading. Setup is not atomic across storage owners; inspect the
manifest after failure. No automatic cleanup/rollback is provided yet: leave run-owned
Profiles for review, remove them through Profile Settings, and restore changed
preferences deliberately using `preferences-before.plist`. Keychain and website-state
changes are not automatically undone. The launcher leaves the target running and
releases its runner claim; coordinate continued interactive ownership.
