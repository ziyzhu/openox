# Chat UX rerender review

## Scope

This review covers SwiftUI update paths in `apps/ios/Ox/Client/Features/Chat`,
especially `ChatPage`, transcript projection and rows, the composer, streaming
text, and viewport state.

The findings come from static dependency tracing. They identify likely body
reevaluations and repeated CPU work, not measured GPU redraws. SwiftUI can
reevaluate a view body and later discard an unchanged subtree. Before changing
architecture, measure body evaluations and projection cost in the simulator.

## Summary

The static review found that the broadest avoidable update path starts in
`ChatPage`. Simulator profiling then found a more expensive active path: every
streamed text delta could remeasure the complete growing `UITextView`. Long
single-paragraph responses reached roughly one CPU core and more than 200 MB of
app-process memory.

The highest-value changes are:

1. Make streaming text storage and layout incremental. Implemented in this
   change.
2. Stop observing composer text from the root `ChatPage`. Implemented in this
   change.
3. Move transcript projection below a narrow transcript-specific view boundary.
   Implemented in this change.
4. Activate the equality boundaries already defined for transcript rows.
5. Cache artifact discovery instead of rescanning the projection during updates.
6. Keep scroll-position changes inside the transcript subtree.

## Existing protections

Preserve these optimizations:

- `ChatComposer` has a custom `Equatable` implementation and its call site uses
  `.equatable()`.
- `TranscriptWindow` limits normal rendering to a tail window rather than the
  complete transcript.
- `Chat` delivers streaming text on display frames instead of publishing every
  provider delta directly to the UI.
- High-frequency viewport geometry is stored in observation-ignored state.
- `ChatViewportController` only publishes `showsJumpButton` when it crosses the
  threshold.
- Streaming fade timelines pause after their pending fade settles.

Related chat UX work removes `composerTop` from
`ChatViewportLayout`. Measuring only composer height prevents global-position
changes from invalidating `ChatPage`. The service and slash pickers now derive
their available space locally with `GeometryReader`, which keeps that geometry
out of root state.

## High-priority update paths

### Growing streaming text remeasures the complete text view

Plain streaming already appended only the new text to `NSTextStorage`, but it
also cleared every cached size. The next SwiftUI layout asked
`UITextView.sizeThatFits` to measure the complete growing response. Formatted
tails additionally replaced the complete attributed string after each parse.
Apple notes that SwiftUI may call a representable's
[`sizeThatFits`](https://developer.apple.com/documentation/swiftui/uiviewrepresentable/sizethatfits%28_%3Auiview%3Acontext%3A%29)
more than once during one layout pass.

Keep one text view so selection can span the response, but make its changing work
incremental. Append a formatted suffix when its attributed prefix is unchanged;
fall back to replacement when completing a link or another syntax change alters
earlier attributes. During streaming, derive height from TextKit's existing
layout manager after the storage mutation. On completion, explicitly leave
streaming mode and restore UIKit's normal sizing path for settled rows. This
uses the incremental layout notifications owned by
[`NSTextStorage`](https://developer.apple.com/documentation/uikit/nstextstorage)
without changing the view's frame directly.

Implementation status: plain and stable formatted growth now append only their
new attributed suffix. Attribute-changing Markdown still replaces the text, and
settled content always uses the original UIKit sizing path. The per-character
`ChatComposer.selection` info log was also removed; selection actions and state
transitions remain observable elsewhere without one log entry per keystroke.

Directional simulator measurements for the same 6.8K plain and 8.4K formatted
Mock scenarios improved from about 95% and 90% CPU to peaks of about 62% and 48%.
The corresponding app-process memory peaks fell from 221 MB and 206 MB to 106 MB
and 140 MB. The after runs contained more settled history and shared a host with
other active simulators, so treat the numbers as directional rather than a
device benchmark. Completed rows retained their full measured heights after
relaunch and another submission; mixed Markdown rendering and range selection
also remained intact.

### Composer text invalidates the root while scrolled away

Before this change, `ChatPage.scrollToBottomOffset` read `composer.isEmpty`,
`composer.draft`, and `composer.draftAttachments`. That function was evaluated
when the scroll-to-bottom button was visible. As a result, typing while scrolled
away could register the root `ChatPage` as an observer of the draft and
reevaluate the whole page for each character.

The offset only needs semantic presentation state:

- focused or unfocused,
- empty or nonempty,
- top strip visible or hidden.

Move the jump-button overlay and offset calculation into a small child view that
observes the composer directly. Another option is a stored presentation state
that changes only when one of those semantic values changes. A computed
`isEmpty` property alone does not solve the problem because it still observes the
entire draft.

Expected result: typing while scrolled away reevaluates the composer and jump
button, not transcript projection or settled rows.

Implementation status: `ScrollToBottomControl` now owns the composer-dependent
offset calculation. `ChatPage` passes stable semantic inputs into that child and
no longer reads draft text or attachments while laying out the jump button. A
simulator focus transition while scrolled away kept the visible transcript
anchor fixed. Ten direct draft mutations triggered no root-page or projection
evaluations after the dependency was isolated.

### Transcript projection runs above unrelated state

Before this change, `ChatPage.page` performed all of the following:

- resolves the transcript window,
- calls `blocksWithTurnID`,
- calls `ChatBlock.project`,
- creates source-ID arrays and sets,
- filters projected blocks,
- derives dock and footer state.

This work can repeat for changes to toast, modal, alert, copy, speech playback,
focus, artifact mutation, and viewport state even when the transcript did not
change.

Move projection into a `ChatTranscriptPane` or equivalent child with narrow
inputs. Keep navigation, alerts, speech overlays, and artifact mutation state
outside that dependency boundary. If projection remains material, cache it using
the document revision, requested source range, thinking activity, and busy state.

Expected result: unrelated page state does not call `ChatBlock.project`.

Implementation status: `ChatTranscriptProjection` now caches a resolved window
behind a key containing the chat identity, monotonic transcript revision,
requested source range, thinking activity, busy state, and active interaction.
The root page can still reevaluate for focus and presentation state without
reprojecting unchanged transcript content. A temporary DEBUG probe measured one
composer focus transition at three projection calls before this change and zero
after it; transcript streaming continued to invalidate projection normally.

### Transcript row equality is not an explicit pruning boundary

`BlockView` and `ResponseFooterBlockView` both define custom equality, but their
call sites do not use `.equatable()`. The equality implementations therefore do
not provide an explicit SwiftUI pruning boundary.

Before applying `.equatable()` to `BlockView`, include `chatID` in its equality
check. It is an input to descendant service-inspector behavior and is currently
omitted. The control closures are intentionally excluded; verify that their
semantics remain stable for equal inputs.

Copy state and speech playback should then update only the affected response
footer. Stable transcript content should not reevaluate when another row changes.

### Artifact discovery repeats full-projection work

`ChatDocument.referencedArtifacts` walks the projection in reverse and rebuilds
its result. `ChatPage` accesses `chatArtifacts` from several render paths,
including the top bar, composer, layout calculations, and artifact presentation.

Store referenced artifacts as derived `ChatDocument` state and refresh them when
the projection changes, or compute one snapshot at the narrowest shared owner and
pass it down. This primarily reduces the cost of an update rather than the number
of updates.

Expected result: streaming a text-only response does not repeatedly rescan the
complete projection for artifacts.

### Scroll position participates in root observation

`ChatPage` owns `ChatViewportController`, binds `scroller.position` inside the
transcript, and reads `scroller.showsJumpButton` inside the dock. Scroll-position
writes can therefore participate in root reevaluation.

Move ownership of the scroll position and geometry callbacks into the transcript
subtree. Expose only low-frequency derived state, such as jump-button visibility,
across the transcript/dock boundary.

Expected result: ordinary scrolling does not reevaluate the composer, top bar,
modal routing, or transcript projection.

## Medium-priority update paths

### Artifact mutation invalidates every row

`artifactRevision` is a single counter passed through `ArtifactControls` to every
`BlockView`. Renaming or deleting one artifact therefore changes the input of all
rows.

Use an invalidation token keyed by artifact identity, or pass a revision only to
rows that render the affected artifact. Text, thinking, and unrelated artifact
rows should remain equal.

### Repeated derived collections add cost to each update

Several values are recomputed or allocated multiple times during a page update:

- `chat.transcript.last?.id` is read while constructing multiple rows,
- `chat.queuedMessages` is rebuilt with `compactMap` from submissions,
- transcript slices are copied into temporary arrays for `ForEach`,
- source block IDs and their `Set` are rebuilt during projection filtering.

Snapshot repeated values once per relevant subtree. Use collection slices with
`ForEach` where their identity remains stable. These are secondary improvements
after update boundaries are narrowed.

### Top-bar inputs are broader than its visible state

`ChatPageTopBar` receives the complete observable `Chat` plus newly created action
closures. During streaming, its visible state usually does not change.

Consider passing a small equatable display snapshot containing only retention
state, temporary state, model display name, block presence, artifact presence,
and busy state. Keep export-state construction behind the export action or menu
presentation rather than ordinary page updates.

## Changes that are unlikely to help

- Do not remove the streaming fade timelines. They already pause when idle and
  their active updates implement the intended animation.
- Do not replace explicit speech or viewport state machines with scattered
  booleans. Their states make transition behavior easier to reason about.
- Do not optimize settled transcript history before activating row equality and
  isolating root dependencies.
- Do not treat every `body` evaluation as a rendered frame. Measure the expensive
  work and visible behavior separately.

## Measurement plan

Use a DEBUG simulator build and collect a baseline before refactoring.

Instrument these boundaries temporarily:

- `ChatPage.body`,
- `ChatBlock.project`,
- `ChatDocument.referencedArtifacts`,
- `BlockView.body`,
- `ResponseFooterBlockView.body`,
- `ChatComposer.body`.

Use SwiftUI change logging for invalidation causes and signposts or counters for
projection and artifact-discovery duration. Keep diagnostics outside committed
production behavior unless they remain useful, structured, and DEBUG-only.

Exercise these flows separately:

1. Type ten characters while at the bottom.
2. Scroll away from the bottom and type ten characters.
3. Stream a long plain-text response while at the bottom.
4. Stream while scrolled away.
5. Copy one settled response.
6. Start and stop read-aloud on one response.
7. Scroll without changing chat content.
8. Rename and delete one artifact.
9. Present and dismiss model, artifact, photo, and file UI.

For each flow, record:

- `ChatPage` body evaluations,
- projection calls and elapsed time,
- artifact-discovery calls and elapsed time,
- settled row body evaluations,
- tail row body evaluations,
- visible scroll or animation regressions.

The target is not zero reevaluation. Each interaction should invalidate the
smallest subtree that owns the changed state, while streaming, scroll anchoring,
keyboard behavior, accessibility, and animations remain unchanged.

## Recommended order

1. Measure the baseline.
2. Isolate composer-dependent jump-button layout. Done in this change.
3. Add a transcript-specific update boundary. Done in this change.
4. Correct `BlockView` equality and apply row `.equatable()` boundaries.
5. Cache referenced artifacts.
6. Isolate scroll ownership.
7. Scope artifact invalidation.
8. Re-measure the same flows before pursuing smaller allocation reductions.
