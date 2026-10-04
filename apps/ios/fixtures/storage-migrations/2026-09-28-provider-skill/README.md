# Manage Providers upgrade fixture

`before/profile.json` and `before/skills/manage-providers/SKILL.md` derive from
files pulled with `sim` from `ox-3` before installing this change. The predecessor
build used the `2026-09-27-outcome-skills` Profile milestone. The Profile UUID and
skill name are sanitized; the encoded shape and existing skill body are retained.
The reference and explicit user selection reuse the serialized shapes from the
existing outcome-skills fixture, with the name substituted for this reservation.

Expected upgrade: only the Profile milestone, reserved package directory/name,
and explicit selection key change. Reference bytes and skill content remain
unchanged. Older fixtures' expected Profile versions advance to the new milestone;
no other expected bytes are changed. The live replay also checks repeat-run
stability, unequal collisions, and interrupted renames.
