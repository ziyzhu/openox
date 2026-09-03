# Photos organization

Verify the `ios:photos` service can inspect authorized photos and organize them into a user album without deleting originals.

Use one owned numbered QA simulator and its matching repository, service, and debug ports. Keep generated test media, screenshots, and logs outside the repository. Start one repository server, verify `/health`, rebuild and install Ox with `sim`, and use `ox` for Host inspection.

## Setup

1. Create six sanitized fixture images outside the repository. Give three visible Japan-themed content and three visibly different content, with deterministic creation dates when the simulator supports them.
2. Add the fixtures to the owned simulator Photos library.
3. Reset Ox's Photos permission for the first run without erasing unrelated simulator data.
4. Launch Ox and select a tool-capable model that accepts image attachments.

## Flow

1. Start a chat and ask Ox to attach Photos and find recent images.
2. Grant limited Photos access and choose only the three Japan fixtures.
3. Verify search returns only authorized, non-hidden assets and reports a bounded page with no GPS fields.
4. Ask Ox to inspect the candidates. Approve `Preview photos` and verify the displayed approval identifies the action.
5. Verify exactly one temporary JPEG contact sheet reaches model context, each tile has a unique label, and the returned label-to-asset mapping matches the sheet.
6. Ask Ox to create `Japan QA` and add the matching fixtures. Approve each write action.
7. Open Photos and verify the new album contains the three expected fixtures while all six originals remain in the library.
8. Ask Ox to remove one fixture from `Japan QA`. Approve the action and verify it leaves the album but remains in the library.
9. Deny a second add operation and verify the album is unchanged.
10. Change limited access so one previously returned asset is no longer shared, then retry the stale batch. Verify Ox reports that id in `missingAssetIDs` and doesn't claim it changed.

## Assertions

- Photos permission appears only after a direct user request invokes a Photos action.
- Limited authorization is usable; denial returns an actionable Settings message.
- Read actions never return hidden assets, coordinates, image bytes, or unbounded results.
- Preview is capped at 20 assets and uses the transient attachment limit.
- Mutations are capped at 200 assets, require runtime approval, and reject system or read-only albums.
- No action deletes, edits, favorites, or otherwise changes an original asset.
- Logs contain permission state, counts, and outcomes without image bytes.

## Failure evidence and cleanup

Capture the failing screen, relevant structured Ox logs, action input and output with fixture-only ids, and the resulting Photos album state. Remove the `Japan QA` album and fixture media after verification, leaving unrelated simulator state intact.
