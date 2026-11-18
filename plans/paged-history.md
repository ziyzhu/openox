# Paged conversation history

Status: proposed; no runtime changes. Make every cost of an open conversation depend on the recent turns rather than the whole history, so a 1,000-turn chat performs like a new one. Do this by storing one self-describing copy per turn instead of joining two partial copies.

## Problem

The conversation is the unit of every operation. `applicationLoad` reads the whole ledger, Swift decodes and projects every entry, `Conversation` holds every turn, and every save sends every turn back across the bridge. Measured on 2026-11-18 (ox-1, Debug, HEAD 32a9bcff, Mock; 2/3 prose replies, 1/3 tool turns with 12 KB results):

| turns | open | hydrate | projection | memory on open | per save | save CPU | tool turn |
|---|---|---|---|---|---|---|---|
| 11 | 561 ms | 53 ms | 30 ms | +91 MB | 0.25 MB | 21 ms | 1,025 ms |
| 300 | 1,500 ms | 761 ms | 340 ms | +212 MB | 7.1 MB | 277 ms | 1,333 ms |
| 1,000 | 6,713 ms | 5,240 ms | 3,640 ms | +498 MB | 24.0 MB | 936 ms | 3,616 ms |

Root causes:
- Each turn is stored twice and rebuilt by inference. Pi model entries carry no turn identity, and `ox.native.presentation` copies carry no entry identity. `DurableConversationProjection.turns` joins them by intent text, timestamps within 1 ms, and content equality across the whole chat. That is O(messages × generations), it makes a partial load impossible, and it produces derived turn IDs that later get saved as duplicate copies.
- `ApplicationPresentation.save` re-reads the whole ledger and serializes every stored turn to decide what changed. Swift sends all turns on every save, and also after every cold open (`attachPersistence`) and every read-state change.
- `ProfileRuntime.decodeConversation` scans every entry once per launch for conversations that never held native entries.
- `TranscriptWindow.reconcile` keeps its lower bound, so a chat left open renders every new block.

## Goal

At 1,000 turns, on the benchmark above: open, hydrate, memory on open, bytes per save, save CPU, and turn latency are each within 1.2× of the 11-turn chat. None of these grows between 300 and 1,000 turns. Opening a legacy chat for the first time may cost one full pass.

Non-goals: model context size (Pi compaction; set a token budget separately) and JSONValue decode speed. Search across history is not built here, but it must query storage, not memory.

## One copy per turn

A presentation copy already holds the complete Swift `Turn` as it was in memory. Make it the source the UI loads, and make it say which Pi entries it covers:

```text
ox.native.presentation data: { turn: Turn, entries: { first: EntryId, last: EntryId } }
```

- Swift fills `entries` from the live events it already receives. `message_end` and `tool_execution_end` carry the Pi entry, but `DurableAgentHost` currently drops its `id`. A user turn covers its user message entry. An agent turn covers its assistant and tool-result entries.
- Transcript order is the order of `entries.first`. The latest copy of a turn ID wins.
- Model entries remain the model's context and the recovery source. They are projected into turns only for the uncovered tail: entries newer than the highest `entries.last` of any loaded copy. These come from a crash mid-turn or from work Pi ran on its own. The tail is projected with today's matching, limited to those entries.
- Restored turns keep their stored IDs, so a load never produces derived IDs that get saved back as duplicates.

## Legacy chats

Copies written before this change have no `entries`. On the first open with the new build, one full pass runs today's projection. It already knows each turn's source entries through its `pi:<profile>:<conversation>:<entry>` step namespaces. The pass appends a single `ox.native.coverage` entry, `{ through: EntryId, turns: [{ id, copy: EntryId | null, first, last }] }`.

- A covered legacy turn loads by projecting only its own range together with the copy that coverage names, so matching is bounded by the size of a turn. Derived duplicate copies are not named, so they are ignored.
- Coverage is immutable and never maintained. If an older build later writes copies without `entries` after `through`, the next open runs the same pass over that gap only and appends another coverage entry.

## Paged load

`applicationLoad` takes `{ reference, before?: EntryId, budget }` and scans newest-first:

- It collects the latest copy per turn ID, and the coverage entry when present, until the page holds at least 16 transcript blocks and 256 KB. The cap is 1 MB unless a single turn is larger. A page ends on a user turn.
- It returns those copies, the uncovered tail entries (first page only), and `earlier` (the scan position, or null).
- A copy found on a later page whose turn ID is already loaded is an older version and is skipped.
- `prepareConversation` skips the legacy native scan once a turn copy with `entries`, or a coverage entry, exists.

## Incremental save

- `Conversation` records which turn IDs changed since the last acknowledged save, plus the canonical size of each saved turn. `ConversationSaveRequest.Payload.conversation(state)` becomes `.turns(meta, changed: [Turn])`.
- Swift applies the running-turn rule (save once the canonical size has doubled; always save a finished turn). JS appends the given turns without reading the ledger and takes the read-state entry from `tx.latestEntryId`.
- Loading never schedules a save. A read-state change sends `.metadata`.

## Partial history in the Host and UI

- `Conversation` carries an explicit history state: `.complete` or `.partial(earlier: EntryId)`. `ConversationDocument` gains a prepend for older turns. Live-tail paths (`reconcileTail`, the running agent turn) touch only the newest turns and stay as they are.
- `TranscriptWindow` caps at both ends. When "earlier" reaches the loaded start and history is `.partial`, it fetches the previous page, prepends, and reuses the existing reveal-earlier anchor. A send made from the bottom trims the window to 16 blocks above the new message once it exceeds 32 (done in step 1). A send made while reading history keeps the window, so on-screen blocks are never removed.
- On deselect, a conversation trims to its newest page, so the five resident conversations hold one page each.
- Full-history consumers read from storage instead of `document.turns`: `ConversationPackage` export (streamed scan), `virtualConversationTranscript`, and `virtualConversationFileSizes`. Branching forks at the entry just before the branch user turn's `entries.first`, so `DurableProfileStore.fork(beforeUser:)` no longer needs a full `applicationLoad` to count user messages. `fileListing(for:)` covers only loaded turns.

## What gets simpler

- The whole-chat annotation and decoration matching in `DurableConversationProjection` runs only for the uncovered tail and the one-time legacy pass.
- `save` stops scanning the ledger and comparing serialized turns.
- Branching stops loading the whole chat to locate its fork entry.
- There is no maintained derived state. Every new record is immutable and describes itself.
- Restored turns keep their IDs, which removes the duplicate-copy bug class.

## Order

1. Cap `TranscriptWindow` at both ends. This is independent and has no storage impact.
2. Incremental save: drop the save on open, send metadata for read state, track changed turns, and use the append-only JS save. No storage change.
3. Parity check: for every finished turn in the benchmark chats and in real exported chats, the latest copy must equal today's projected turn apart from IDs. Investigate each difference before continuing.
4. Stamp `entries` on new copies, add the legacy coverage pass, and load turns from copies. Write storage before/after fixtures and check that a predecessor build can read the result.
5. Paged load and partial history, plus the storage-backed full-history consumers.
6. Re-run the benchmark after each step. The benchmark chats (`…0111` at 1,000 turns, `…0427` baseline) remain on ox-1.

## Compatibility

- New persisted state: an additive `entries` field next to `turn` in presentation data, and one new entry kind, `ox.native.coverage`. Predecessor readers decode only `data.turn` and must ignore the coverage entry. Verify both, including export and import.
- A predecessor still loads a chat through its full projection, so chats written by the new build must keep model entries complete. They do, because nothing here changes what Pi writes.
- No Host RPC or CLI change. `ox conversation inspect` keeps returning all blocks by reading storage.

## Open questions

- Pi inbox steering and queued submissions: can a user message entry land inside a running agent turn's range? If so, an agent turn's `entries` may be non-contiguous and needs a list rather than bounds.
- Copies repeat tool results that the model entries already hold. Once copies name their entries, a copy could store only UI-only fields and read results from its own range, which would roughly halve storage. Decide after step 5.
- Should the page budget scale with device memory?
