# Web model conversation continuity

Status: draft implementation plan.

An Ox chat should continue the same website conversation across model responses, Action results, and later user messages. A generation ends when its response finishes; the conversation survives. The browser page may be retained or released independently.

## Intended behavior

```text
Ox Profile + chat + provider/account binding
└── Website conversation
    ├── Remote conversation identity and confirmed transcript position
    ├── Generation 1: initial context and attachments
    ├── Generation 2: new Action results
    ├── Generation 3: later user message and new attachments
    └── Page lease
        ├── Retain while active or recently used
        ├── Release when idle under capacity or memory pressure
        └── Reopen the same conversation and verify before continuing
```

Ordinary service Actions keep their separate execution pages. The initial implementation supports continuation explicitly per service; older services retain their current behavior.

## 1. Define a compatible conversation contract

Keep the existing four model Actions valid. Design an additive, separately validated continuation Action set, discoverable through existing Action definitions, without adding a manifest kind or top-level manifest fields. Finalize exact names and schemas before implementation. Any required manifest-schema change remains a maintainer approval item.

The new contract must support creating or opening a conversation, verifying its account and remote message position, submitting new input against an expected position, observing a generation, and reporting cancellation truthfully. Return opaque conversation, submission, and message references rather than website internals in generic Host code.

Separate submission acceptance from response completion. A Host request ID helps correlate attempts but is not a promise of website-side deduplication. Services must report when acceptance or the current remote position cannot be established. Reject unsupported continuation capabilities before submitting.

Acceptance: old services still validate; incomplete new contracts fail validation; supported services can perform two sequential generations in one conversation.

## 2. Give conversations an explicit owner

Pass a provider-neutral execution scope from the chat through agent snapshots to the provider. The scope identifies Profile, chat, conversation epoch, and request purpose. API providers may ignore it. Auxiliary requests such as compaction summaries must not append to the user's website conversation.

Compose a web conversation coordinator with the generic web provider. Bind sessions to the selected service source, verified account, and model compatibility. Keep conversation identity separate from page ownership and generation state. Never put chat-specific mutable state on a shared provider-registry instance.

Use explicit states for opening, ready, submitting, generating, needing reconciliation, and unavailable. Hold the existing domain concurrency reservation only during active work, not for the lifetime of an idle conversation. Queue competing work with cancellation; do not increase website concurrency until it has been verified.

Acceptance: chats remain isolated; Action continuations retain their owner; idle conversations do not block other chats; compaction uses a separate scope.

## 3. Send incremental input safely

For a new website conversation, send the effective initial instructions, context, and required attachments. Once synchronized, send only newly added user messages and Action results. Do not echo the website's own assistant response back to it.

Track confirmed submission and completed output separately, with stable local message identities or canonical fingerprints and corresponding remote positions. Advance synchronization only on observed acceptance and verified output. Map Ox Action envelopes to the exact remote assistant message without relying on raw message counts.

Upload only attachments required by new input. Reuse remote attachment references only where the service has verified their lifetime and availability. Do not treat a repeated filename as proof of an existing upload.

When history ceases to be an extension of the synchronized transcript, create a new conversation epoch from the effective Ox context. This includes compaction, edits, retries that change a branch, and incompatible instruction or tool changes. Model changes may continue only if the service verifies that transition. Switching providers or accounts requires a compatible new binding. Returning to an older binding requires transcript reconciliation.

Acceptance: a user message, two Action exchanges, and a follow-up use one remote conversation without duplicated history or attachment uploads. Divergent history never appends to a stale branch.

## 4. Reuse pages and bound their lifetime

Keep a healthy conversation page after generation completion. Reset generation-specific observers, buffers, and staged files while preserving the website conversation and its native state. Retain bounded read history until the Host has acknowledged completion; a lost read response must remain repeatable.

Use a bounded idle-page cache with least-recently-used eviction. Pin pages during submission, generation, and reconciliation. Release idle pages on memory warnings, chat deletion, Profile/account changes, and incompatible service invalidation. Reopening a page must verify the account, conversation, and remote position before appending.

Keep model pages separate from ordinary service pages. If this work shares the service pool's eviction machinery, first fix its reproduced empty-queue eviction bug and add a capacity regression test.

Acceptance: consecutive healthy generations require no new page or full navigation. Eviction preserves conversation identity and does not cancel active work.

## 5. Persist identity and handle interruptions

Persist a versioned conversation reference and synchronization metadata with the owning chat, following the existing chat-storage ownership. Record a pending submission intent durably before a side effect and persist observed acceptance afterward. Keep credentials in existing credential storage and live pages in memory. Compare the existing storage gate and shipped representation before choosing an additive format or migration milestone; all compatibility handling belongs in StorageMigrator.

On relaunch or page loss, inspect the remote conversation before sending. If a pending request is found, recover its observed state or completed response. If the service cannot prove whether it was accepted, expose the uncertainty and require an explicit recovery choice. Never automatically resend an uncertain request. A local timeout or closed page does not prove remote cancellation.

Verify the remote position again before appending after inactivity, including possible changes from another device or the website itself. Do not silently merge external messages. Forked or imported chats must not inherit permission to append to the original chat's remote conversation. Deleting an Ox chat releases local state; remote conversation deletion is a separate user action.

Acceptance: crash windows before and after submission do not cause automatic duplicate messages; relaunch can resume a verified conversation; old chats load without losing data.

## 6. Prove one service through Ox

Choose one continuation-capable service available on the user-selected iOS 26 QA simulator. Establish its native conversation identity, append behavior, account checks, attachments, and completion evidence through the built-in manage-services workflow. Author and verify a Local copy inside Ox, preserving unrelated edits. Do not write website behavior directly from Codex. Promotion into the built-in repository follows a separate explicit promotion request.

Update the manage-services model contract and the relevant provider guidance alongside the Host changes, replacing the current one-generation-per-page assumptions. Keep unsupported services on the existing contract while extending coverage one service at a time.

## 7. Verify correctness and measure the improvement

Run deterministic lifecycle and synchronization tests for sequential generations, Action loops, queued chats, cancellation, lost reads, uncertain submissions, page eviction, relaunch, account changes, source updates, forks, and compaction. Use the storage upgrade gate and sanitized predecessor fixtures for persisted changes. Run typecheck and relevant service-contract tests; rebuild the service bundle when built-in sources or the compiler change.

Build and exercise the iOS flow with sim. Use the same provider, prompt, attachments, and device for before/after comparisons. Record page creations, full navigations, bytes staged, upload count, submission latency, first-text latency, and resident page counts. Capture WebKit memory as well as app memory where tooling permits. Separate provider inference time from Host preparation time.

Success criteria:

- One remote conversation across an Action loop and later user messages.
- No full page reload between healthy consecutive generations.
- No duplicate transcript submission or reupload of already synchronized attachments.
- Page eviction or relaunch reopens the existing verified conversation.
- Uncertain submission never triggers an automatic resend.
- Resident idle pages remain bounded and shrink under memory pressure.
- Existing services, saved selections, sign-in state, and ordinary Actions remain functional.

Deliver in three reviewable slices: additive contract and ownership; live continuation and page reuse for one Local service; durable resume and interruption recovery. Complete all three before claiming conversation continuity across app restarts.
