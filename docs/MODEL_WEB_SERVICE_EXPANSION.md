# Assistant web services as model providers

Status: Gemini and Doubao implemented and saved in Local, with live Ox Action and conversation-context verification. The remaining four candidates still require their own verification. Builds on commit `22ef111`, which moved Qwen, Kimi, Grok, and Claude into editable web services.

## Implementation evidence

- Initial account probes on ox-qa-5 found Gemini signed in and the other candidates signed out. Doubao has since been signed in and explored; check the remaining services afresh before implementation.
- Gemini now exposes the four standard model Actions through the generic provider, alongside its preserved ordinary Actions. The website picker remains available as `listWebsiteModels`.
- The first release advertises the default text model with final-only output. Native fetch and XHR responses supply explicit completion markers, correlated with the submitted conversation. Hidden-page rendering state remains busy after completion and is not used as the completion signal.
- Gemini's native editor truncates input at 32,000 JavaScript string units. The model service rejects oversized serialized context before submission with a context-overflow failure; it never drops instructions or history. Token limits remain unknown because this is a character limit.
- Live generic-provider text passed. A real Ox chat executed `console.log(7 * 8)`, consumed the returned `56`, and recalled both that result and `MAPLE-847` in a follow-up turn with full Ox instructions present. Ordinary website model discovery also passed.
- Direct `ox vm call ox.service.attach` from an idle chat cannot present the first-attachment prompt because no agent run is active. First attachment succeeded through the app's Services picker; subsequent CLI attachment calls reloaded the validated Local draft. A trial tracking change did not resolve the underlying run-state requirement and was discarded.
- Synthetic transport/parser fixtures cover fetch and XHR, native completion flags, response identity, malformed and oversized responses, preserved answer formatting, and input limits. The existing shared lifecycle tests also cover Gemini.
- All 83 focused tests pass, along with typechecking and bundle compilation. The app builds and launches on ox-qa-5 (iOS 26.5). The saved Gemini selection survives restart; saved Local JavaScript matches the repository and generated bundle, and Local has no pending changes.

Gemini does not yet advertise selectable website modes, attachments, incremental streaming, or confirmed remote cancellation. Cancellation before submission is confirmed; after submission it is reported as unsupported. The remaining candidates must pass the same live gates before becoming model providers.

### Doubao implementation evidence

- Copied the built-in service to Local and activated all four standard model Actions without a new manifest field or Swift provider. The Host discovers one `web:doubao.com` entry using the existing account.
- Doubao initializes its native submission machinery inside `requestAnimationFrame`, which stalls on hidden pages. A document-start fallback schedules those callbacks while hidden, preserves cancellation, and invokes each callback at most once. Ordinary synthetic chat passed after this fix.
- The adapter observes the native `/chat/completion` request through fetch or XHR. It correlates the acknowledged question, exact submitted prompt, conversation, and assistant message; reconstructs text patches; and requires native message, answer, and stream completion markers before publishing a final answer.
- Standardized lifecycle and fresh owned-page generic-provider text tests passed. Synthetic fixtures cover both transports, mismatched identities, incomplete answers, unsupported content, bounded response size, cancellation, hidden-page scheduling, and the shared cursor/lifecycle contract. Typecheck and bundle compilation pass.
- Long user messages are collapsed in Doubao's DOM. Completion uses the exact server-echoed prompt and matching question/answer identities, plus the conversation route, rather than requiring the collapsed DOM to reproduce the full prompt. The full Ox prompt exceeded 33,000 characters during verification.
- A real Ox chat called `execute` with `console.log(8 * 9)`, received `72`, and consumed the result in its final answer. A follow-up correctly recalled both `CEDAR-926` and `72` without another Action.
- Capabilities are limited to the default text model and final-only output. Token limits are unknown; selectable modes, uploads, generation options, incremental streaming, and remote cancellation are not advertised.
- Saved Local commit `7d62922177a5088b05e7f27bfd6fe121039a6b43`; Local is clean. Saved JavaScript matches the built-in source and generated bundle. All 96 focused tests pass, alongside typecheck and bundle compilation. A forced iOS build installed and launched on ox-qa-5, the saved Doubao selection survived restart, the registry contained one provider entry, and a fresh generation returned `DOUBAO_RESTART_READY`.
- Source activation requires reloading the service attachment after Local edits. The debug page-reload command alone can retain the prior loaded service definition. First attach the service through the picker when the QA chat is idle, then use `ox.service.attach` for subsequent revisions.

## Outcome and scope

Microsoft Copilot follow-up: the fresh server-authoritative sign-in check passed on ox-qa-5. A synthetic send opened a native “Verification required” dialog, left the draft intact, and did not confirm a submitted conversation. After the user completed the visible-page handoff, a new service-page test again required Cloudflare Turnstile verification; its only observed chat WebSocket response was a heartbeat. Sign-in remains valid, but visible-page verification did not carry over to the hidden service page. Native submission uses a WebSocket connection to Microsoft's substrate service. Capture was stopped.

Copilot now has a validated, uncommitted Local draft on ox-qa-5 with `getBotControlUrl`, `getBotControlState`, and `BOT_CONTROL_REQUIRED` detection for the observed dialog. It retains the exact pending message arguments, returns the current page URL without resubmission, and rejects missing, mismatched, expired, or changed conversation state. Five offline checks passed, including challenge disappearance and unconfirmed text remaining pending. The draft's completion predicate still needs live confirmation; the existing Host retains ordinary Action pages, but model-owned page handoff remains a separate integration requirement. The user approved Microsoft Copilot integration tests, including model instructions and Action schemas. The test-driving Doubao generation failed before invoking Copilot. Automatic approval review blocked using the separately authenticated GitHub Copilot as an alternative test driver; the chat selection was restored to Doubao. Direct idle VM execution cannot present the required approval or retain a bot-control source because those paths require an active chat run. Do not Save, promote, or expose model capability until same-page human verification and native completion have been verified. The user subsequently selected ChatGPT (GPT-6 Sol) on ox-qa-5. Its live test attached the Local Copilot draft and obtained approval for one synthetic message, but Copilot returned signed out at the authentication gate before submission. A separate fresh sign-in probe also returned false. ChatGPT then returned a usage-limit error. After the user signed in again, the fresh sign-in probe passed and ChatGPT resumed the test. One authorized send raised `BOT_CONTROL_REQUIRED`; Ox called `ox.service.solve` with the same message and presented the retained Action page. Runtime logs confirmed the same page identity for submission and handoff, and the visible page showed the Turnstile checkbox with the synthetic draft intact. Human verification and post-verification completion remain pending.

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
