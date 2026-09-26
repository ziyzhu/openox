# Assistant web services as model providers

Status: draft. Builds on commit `22ef111`, which moved Qwen, Kimi, Grok, and Claude into editable web services. No expansion implementation is included in this plan.

## Outcome and scope

Extend the six remaining assistant web services below with the existing standard model Actions. They should appear in Ox's model picker, use their existing website accounts and storage, and remain editable through the normal Local service workflow. ChatGPT is excluded because its existing account integration already covers the intended access.

Keep the existing API and subscription providers available. A website account does not imply API access, and Microsoft Copilot is distinct from GitHub Copilot.

## Candidates and current evidence

These observations come from the checked-in service manifests, not fresh website verification. The user has indicated account access is available; the most recent simulator status reports unknown sign-in state for these six services. Verify access before implementation rather than treating unknown as signed out or authenticated.

| Service | Existing support | Main gap to establish live |
| --- | --- | --- |
| Z.ai (`chat.z.ai`) | Model IDs, chat submission, server conversation messages with completion markers | Reliable model selection and completion for the exact submitted turn |
| DeepSeek (`chat.deepseek.com`) | Chat submission and server conversation reads | Authoritative completion detection; current read schema lacks an explicit completion flag |
| Gemini (`gemini.google.com`) | Live model/mode picker, chat submission, rendered conversation reads | Distinguishing modes from model identities and verifying a finished answer |
| Doubao (`doubao.com`) | New/continued chats and bounded rendered conversation reads | Exact turn identity and completion; an observed reply may still be generating |
| Perplexity (`www.perplexity.ai`) | Chat submission, thread reads, citations, model catalog | Account-available selection, final completion, citation rendering, and Ox Action-envelope fidelity |
| Microsoft Copilot (`copilot.com`) | Conversation reads, generation state, response modes | Sending remains explicitly experimental/unverified in the current manifest |

Proposed sequence: Z.ai first, then DeepSeek, Gemini, Doubao, Perplexity, and Copilot. This order reflects the current service contracts. Reorder if live access or implementation readiness warrants it; do not hold verified services behind a blocked candidate.

## Architecture

Use `WebServiceModelProvider` and the existing session/runtime without adding provider-specific Swift clients or new manifest fields. New provider identities derive from the service domain (`web:<domain>`); model IDs retain the existing generic persistence rules. Model generation and ordinary Actions use the same resolved source and website storage.

Each service implements the exact schemas for:

- `listModels`
- `startModelGeneration`
- `readModelGeneration`
- `cancelModelGeneration`

Preserve the existing incompatible `listModels` Actions on Gemini, Z.ai, and Perplexity as `listWebsiteModels`. Preserve other ordinary Actions and their approval behavior. Share website helpers within each service; do not merely wrap a blocking ordinary chat Action whose result may only mean submission was accepted.

Start with a working `website-default` text model. Add explicit selectable models only when their identity, account availability, and selection are verified. Do not invent underlying model names for website response modes. Advertise streaming, cancellation, options, and attachments only when their behavior is demonstrated. Unknown token limits stay null.

No persisted schema change is expected. If implementation reveals one, route compatibility work through `StorageMigrator` and the storage-migrations skill.

## Work packages

### 1. Establish account and service readiness

On ox-qa-5, verify the iOS 26 runtime, current service source, Local repository state, and fresh `getSignInState` for each candidate. Record accessible models/modes and any account restrictions without copying credentials. Inspect existing drafts and avoid overwriting them.

For each candidate, identify how to submit once, correlate the remote conversation and assistant turn, observe final completion, and request cancellation. Distinguish accepted submission, text becoming visible, and completed generation. Read-only exploration precedes synthetic test prompts.

Acceptance: a small per-service capability matrix backed by live observations, with unavailable candidates explicitly marked pending.

### 2. Complete Z.ai as the first vertical slice

Follow the user's direct-authoring instruction and the same built-in `manage-services` system skill used by Ox. Copy the built-in service to Local, resolve its source conflict through the existing flow, author the standard Actions, validate, activate, exercise, and Save. Use Ox service operations for the lifecycle and live verification.

Serialize the complete structured conversation, including system instructions and the Ox Action envelope. Keep generation state on the owned page; bound polling and retained events. Correlate reads with the submitted turn. Return append-only snapshots or one final snapshot, with explicit terminal state and truthful cancellation results.

Acceptance: Z.ai works in a real Ox chat, performs a harmless Ox Action and consumes its result, preserves multi-turn context, and uses an edited Local implementation for the next generation without an app rebuild or duplicate provider entry.

### 3. Extend the remaining five services individually

Repeat the verified workflow, reusing site-specific helpers already present in each service. Use final-only output when intermediate text can be rewritten or completion is easier to verify reliably. Never equate stream EOF, stable text, or an enabled composer alone with remote completion.

For Perplexity, preserve citation URLs in the returned answer text and verify that source enrichment does not revise text already emitted. Respect the existing website privacy mode. For Copilot, establish reliable one-time submission before exposing model capability; otherwise retain it as an ordinary service with the limitation documented.

Do not derive website context capacity from the existing ordinary Action character caps. Exercise full Ox instructions, tool schemas, conversation history, and Action results. Reject excess input with an explicit context error when a limit is known; never silently truncate instructions or history.

Add image/document capabilities only after real uploads and model comprehension pass with synthetic fixtures. Text-only capability is a valid first release for each service.

Acceptance: every enabled candidate passes the verification matrix below. Failed candidates remain ordinary services until their missing behavior is verified.

### 4. Publish verified built-in sources and documentation

After Local validation, live verification, and Save, bring the verified sources into the built-in repository as part of the approved expansion. Preserve unrelated Local edits. Add sanitized replay/regression fixtures, rebuild the generated services bundle, and ensure source/bundle parity.

Update provider references only for website account context and links to the owning service. Clarify the model-providers skill's distinction between native API composition and adding model Actions to an existing web service so future work does not recreate site-specific Swift adapters. Capture reusable authoring or diagnostic improvements discovered during this work.

Acceptance: each promoted service has reproducible verification evidence, accurate capability metadata, ordinary Action compatibility, and an updated generated bundle.

## Verification matrix

Run these checks for every newly enabled provider:

- Fresh sign-in check, shared account access, and clear authentication failure. Use fixtures for expired/signed-out cases when logging out would disrupt the user's session.
- Default text generation, every advertised selectable model, full Ox prompt capacity, multi-turn context, and a complete Ox Action round trip.
- Exact conversation/turn correlation, repeated reads, valid cursors, confirmed completion, and truthful cancellation while reads are pending.
- Typed rate-limit, unsupported-input, and context failures; uncertain submission must not trigger a second send.
- Page interruption and source changes without automatic resubmission; active and subsequent generations follow the existing session contract.
- Ordinary Actions still work; Local copy, conflict resolution, validation, activation, Save, and reload preserve provider identity and selected source.
- Synthetic image/PDF comprehension for each advertised modality; reject unsupported attachments before submission.
- Saved provider/model selection still resolves after restart. Verify an existing migrated provider alongside the new candidates as a shared-runtime regression check.

Run the existing model contract/stream/bridge tests plus focused new service fixtures, `bun run typecheck`, and `bun run build:services`. Build/install/launch with `sim` and exercise the real model-picker/chat flow on ox-qa-5. Keep diagnostics outside the repository and restore any changed simulator settings. Review changed lines and complexity before each versioned commit.

## Boundaries

No ChatGPT website provider, automatic recovery, fallback selection, durable generation resumption, or new manifest kind/field. Account access is a prerequisite, not proof of model-provider reliability. Enable each service only after verified submission, final answers, and Ox Action handling work through the generic adapter.
