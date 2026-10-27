# Storage upgrade cases

Maintain explicit X-to-Y cases when storage changes. No automated upgrade case is
currently established; portable checks and conversation smoke do not count.

Each case records the source release, exact source revision/build, target
revision/build, affected storage owners, immutable milestone identities, snapshot
hashes, expected preserved data, allowed transformations and private evidence path.
The supported historical source versions must be chosen explicitly; do not infer
support for every release from one predecessor.

Use actual predecessor-written `before.json` and target-written `after.json`
templates with immutable external snapshots. Validate inputs with
`bun run sim:launch --template <path> --validate`. Follow
[the upgrade procedure](../references/storage-compatibility.md) to run X/before,
Y/before and Y/after on isolated reserved targets and verify ordinary writes and
second-launch stability. Retain exact commands, full tree comparisons and structured
migration logs for each row. Cover interruption/recovery and future-version rejection
when relevant. Never replay over personal data or downgrade a migrated container.

Missing historical builds or snapshots are a blocker, not permission to synthesize
old data using current types. Add concrete cases only after the predecessor artifacts
and expected data are available.
