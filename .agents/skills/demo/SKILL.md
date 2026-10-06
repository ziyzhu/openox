---
name: demo
description: "Prepare and record the three-part Ox iOS demo: Connect anything, Local first, and Yours. Use when recording, recreating, or preparing this specific demo."
---

# Ox Demo

Use the `sim-cli` skill for visible iOS interaction and the `ox-cli` skill to verify selected chats, models, service state, and completed replies. Use the `evolve` skill for the live Reddit service-creation scene. Follow the repository's simulator rules. Keep recordings, response drafts, and the run manifest outside the repository.

## Story and opening

Use the existing feature copy verbatim for the opening and chapter introductions, in this order. Do not add a separate tagline or rewrite the descriptions; they remain identical to the README, onboarding, and website:

**Connect anything**
Ox works across AI assistants, apps, and websites to get things done for you.

**Local first**
Ox runs on your device, keeping your conversations, credentials, and memory stored locally.

**Yours**
Open source and malleable, Ox evolves with you and uses the models you choose.

Introduce each chapter with its exact heading and description before its footage, through narration or an existing product screen, not a composited card over the app. Do not change public feature copy or add app UI solely for the recording without a separate request. Avoid claims that all models run locally, all services work offline, or every assistant exposes all of its memory. Use write-action examples: send, schedule, add, open a pull request, publish, or update. Do not substitute read-only searches, advice, reports, or draft-only outcomes. Live writes still require the app's normal approvals and explicitly authorized demo recipients, repositories, and posting targets; choosing a preview example does not authorize a real send or publication.

## Native SwiftUI preview mode

Use this mode when the user explicitly requests a controlled SwiftUI preview rather than live execution. Open `apps/ios/Ox/Development/OxDemoSceneView.swift` and use its `#Preview` scenes. Reuse production onboarding rows, chat header, composer, message bubbles, Markdown, service chips, and provider picker rows. Apply the production `.themed()` modifier; a SwiftUI-only theme override does not initialize the theme used by UIKit Markdown text. Reuse `ThinkingRow` for scripted progress and `ResponseFooterBlockView` for completed replies; keep response controls hidden during work and streaming. Use task-specific outcomes and limitations rather than generic success copy, and preserve the exact reply text when streaming word bursts. Match `ConversationPage`'s scaled control metrics: 44-point header icons and a 34-point composer circle inside a 44-point tap target. **Do not add player controls, demo labels, custom cards, overlays, simulated system controls, or other special recording UI.** Scene selection and timing belong outside the rendered app, in Xcode previews or launch configuration.

For a simulator snapshot:

```bash
sim --device <owned-device> run ai.oxcraft.bot \
  --project apps/ios/Ox.xcodeproj --scheme ios \
  --env OX_DEMO=1 --env OX_DEMO_SCENE=memory --env OX_DEMO_COMPLETE=1
```

`OX_DEMO_SCENE` accepts `connect`, `memory`, `planning`, `publishing`, `local`, `offline`, `yours`, `providers`, `reddit`, or `reuse`. Use `OX_DEMO_AUTOPLAY=1` without `OX_DEMO_COMPLETE=1` for the timeline. Relaunch without demo environment variables to return to normal Ox. This entry point and its fixtures are DEBUG-only; demo artwork is excluded from Release builds. Start recording before autoplay; simulator command latency can otherwise miss the opening chapter. Trim the relaunch transition and verify the opening in the exported video.

The preview uses in-memory, illustrative data and local artwork. Task traces, source-specific replies, and streaming cadence are scripted presentation fixtures, not captured model reasoning or evidence of completed operations. Service chips use the production status layout with snapshot-only auth state; preview status indicators are not proof of a real sign-in or native permission grant. It bypasses normal Host preparation and performs no model requests, account imports, service execution, or persisted service creation. Disclose this distinction in the accompanying description or delivery notes, not through extra in-app UI. The `offline` preview presents existing messages only; it does not demonstrate offline inference or change radio settings. A real airplane-mode action still requires separate system footage, following the live requirements below. Do not present preview screenshots as evidence that signed-out services succeeded.

Run `bun run test:demo --device <owned-device>` to check native rendering, exact prompts and service assignments, absence of special UI, and unchanged profile/Local repository contents. This checks presentation fixtures, not live integrations. Keep its private diagnostics outside the repository.

## App Store screenshot previews

`apps/ios/Ox/Development/OxAppStoreScreenshotView.swift` contains six named, static `#Preview`s: planning, publishing, memory, reminder, service creation, and publishing with the created service. They render completed conversations through the same production components, with no autoplay, titles, device frames, or overlays. The storyboard's planning/publishing scenes remain typing-only.

Launch with `sim --device <owned-device> run ai.oxcraft.bot --app <Ox.app> --env OX_APP_STORE_SCREENSHOT=planning`. The selector also accepts `publishing`, `memory`, `reminder`, `service`, and `post`. Capture with `sim screenshot` after `demo.reply` settles; `test:demo` exports and checks all six under its private `app-store/` diagnostics directory. Keep original PNGs at native resolution and check [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) for the target display class. These are illustrative layout previews, not evidence of actual writes or upload approval; verify depicted capabilities before publishing. Relaunch without the screenshot selector to restore normal Ox.

## Prepare

1. Use the requested simulator, normally `ox-1`, and confirm Ox is ready with bundled services. Check ownership before using it. If the simulator cannot demonstrate a real airplane-mode transition and offline inference, coordinate a paired physical device with the user; do not replace that action with a mock toggle.
2. Reuse prepared empty chats only when their service attachments match; create missing chats as needed. Prepare these three **Connect anything** chats:

   | Scene | Attached services | Exact prompt | Saved response file |
   | --- | --- | --- | --- |
   | Memory | ChatGPT, Claude, Muse | Import my memory from ChatGPT, Claude, and Muse into Ox, and merge duplicates. | `01-memory.md` |
   | Planning | Gmail, Calendar, Reminders | Email Alex that the release is ready, schedule a review tomorrow at 10, and add a prep reminder at 9. | `02-planning.md` |
   | Publishing | GitHub, Gmail, Reminders | Open a pull request for feature/checklist in my demo repo, email Alex the link, and add a review reminder. | `03-publishing.md` |

3. **Sign-in is a hard preflight gate.** Verify the attached website services, plus Reddit for **Yours**, are signed in on the recording device, and verify Calendar/Reminders permissions. Prepare an explicitly authorized demo contact named Alex and a demo repository with a `feature/checklist` branch; do not infer targets or contact real people for QA. Open each service in Ox and perform a harmless authenticated read using the same session the demo will use. A service chip, stored cookie, or public landing page is not proof of authentication. Record the service, check time, and result in the private run manifest; never copy credentials or identifying account details into shared artifacts. Resolve expired sessions, challenges, and missing permissions before recording. Ask the user to complete any interactive sign-in or MFA. Do not claim the full demo is ready while any required service is blocked.
4. **Use a real ChatGPT model by default, not replay.** Find a free simulator with an existing ChatGPT provider sign-in, select an available model in Ox, and verify a harmless live reply before recording. Provider authentication is separate from the ChatGPT website service's sign-in; verify both. Keep the default model unchanged unless needed, and record any settings changed for the demo. Run the three Connect anything prompts against the real signed-in services, checking which memory each assistant exposes and verifying the actual email, Calendar event, Reminders, and pull request after approved execution. Save actual outputs privately. Review live replies before sharing footage; re-record with non-identifying demo data or omit private content rather than substituting sanitized replay without approval. Do not fabricate success; imported memory must really be persisted before showing an import as complete.
5. **Replay is optional and requires an explicit request.** For repeatable **Connect anything** footage only, start `bun run .agents/skills/demo/scripts/replay-server.ts --responses <sanitized-response-directory> --port 8082` and verify `http://127.0.0.1:8082/health`. The directory must contain `01-memory.md`, `02-planning.md`, and `03-publishing.md`, prepared from saved GPT-5.6 Luna · Fast runs with private details removed. Regenerate these responses after prompt changes; an old advice-only response does not demonstrate the new action-oriented request. The server exposes `Bonsai 2 27B` as a local OpenAI-compatible replay model. Configure its custom provider URL in Ox as `http://127.0.0.1:8082/v1`, select that model, and tap **Save**. Verify the chat header shows Bonsai. Disclose outside the recording that these answers are replayed from Luna runs; the replay does not execute service calls or memory imports.
6. Prepare **Local first** separately: verify a genuinely on-device inference path works without network access. The host-side replay server, cloud providers, cached replies, and Mock do not establish offline inference. If no supported local inference path is available, mark this scene blocked and ask the user to choose between implementing one and showing only offline access to existing local conversations. Do not silently substitute the latter for a new offline conversation.
7. Prepare **Yours** with the model-provider list and a live Reddit service-creation flow. Verify the authoring model and required tools work. Use a separate disposable profile for chats and memory, sign into Reddit, and verify the device has no installed Reddit service so the recording can show real creation. Profiles do not isolate the shared Local service worktree: inspect its pending changes before authoring, and never include unrelated work in Save. If scoped Save is unavailable, preserve the verified draft and report that limit. Do not delete an existing Reddit service just to recreate it or modify the prepared Connect anything profile. Record the initial state and resulting service identifier in the manifest.

## Iterate efficiently

- Reuse configured providers and authenticated sessions when they match this storyboard. Recheck authentication before a take rather than repeating sign-in unnecessarily. Reuse sanitized response files and a healthy replay server only for explicitly requested replay footage.
- Keep a private run manifest with the device, profile and chat IDs, sign-in checks, actual pre-run results and limitations, inference mode per scene, response directory, raw scene paths, source trim timestamps, original radio settings, and final export command.
- Preserve each scene separately. Before a full take, review a short sample covering typing, cursor blinking, Send, and keyboard dismissal. Confirm text and composer move together and export timing matches the source. Reuse a successful sample as finished footage when possible.
- For a revision, record only scenes whose visible content changed. For timing or trimming changes, re-export existing raw captures. Verify changed scenes and final joins without repeating unrelated setup.
- Trim using source timestamps, reset each trimmed clip to zero, then convert to a constant frame rate. Preserve pauses and cursor cadence on the first export.
- For a commit-only follow-up, review the diff, complete repository-required commit checks, and reuse completed validation unless changes invalidate it.

## Record

Record simulator footage with `sim --device <device> record-video start --out <path.mov>` and `sim --device <device> record-video stop`; use the documented device recording flow for a paired physical target. Capture actual app and system interaction, without composited cards or overlays.

### 1. Connect anything

1. Show three distinct chats in the table's order, each with only its assigned three service chips. The previous desk/Seattle/catch-up scenes and eight-chip swipe do not apply.
2. Confirm the composer is empty: attaching services through the picker can leave a leading space. Focus with a brief tap, not a press-and-hold, and verify the focused composer has settled before typing. Type each complete exact prompt in one input action. Simulator HID input can finish after `sim type` returns or drop text during composer/keyboard movement: inspect the field until its complete value is stable and exactly matches the prompt. Then hold it on screen for about one second before Send or ending a typing-only scene. Apply this check to every chapter's prompts; never send a mismatched field. If entry fails, correct it off-camera and record a clean take.
3. Show the memory prompt and its verified live reply, reviewed for privacy. Cut from the completed prompt to the anchored message to skip the send animation. End the planning and publishing scenes on their completed typed prompts, before their replies appear. Still send and verify their real responses off-camera so all three chats are validated. Use saved replay replies only when explicitly requested.
4. Start with about 0.9 seconds of empty composer; hold the completed memory prompt about 1.1 seconds, its reply stream plus about 0.6 seconds, and each later completed prompt about 1.5–1.7 seconds. Adjust for readability of the new prompts rather than forcing the previous runtime. Cut around paste menus, autocorrect flashes, and unsynchronized keyboard dismissal.

### 2. Local first

1. Start this chapter with the visible action of turning **Airplane Mode on** in the system UI. **Keep that action in the final recording.** Confirm Wi-Fi and cellular data are off; airplane mode may preserve Wi-Fi. Do not cut from an online conversation to an offline icon and imply the reply was generated offline.
2. Return to Ox, show the verified on-device model, and start a fresh simple conversation. Suggested prompt: “Add a reminder for tomorrow at 9 to start a 45-minute focus block.” Keep the send and completed live reply in the recording. Attach only the on-device Reminders service; use no network-dependent tools. Verify the new reminder separately.
3. Verify the reply was generated after disconnection, not preloaded, replayed, or cached. Keep diagnostic evidence outside the repository. If the device cannot complete this flow, stop and report the blocker rather than presenting a simulated success.
4. Restore the device's original radio settings before the next chapter and after failures. Verify connectivity before the live Reddit scene.

### 3. Yours

1. Show the **model-provider list view**, with readable provider names and no exposed keys or account identifiers. Present model choice neutrally; do not imply every listed provider is configured or available offline.
2. Switch to the prepared disposable profile and show Ox using Reddit through the live website workflow. Suggested prompt: “Create a reusable Reddit service that can publish posts and reply to comments.” The wording is provisional until the real authoring flow is verified.
3. Capture actual service creation while Ox works with the site. Show the resulting Reddit service in the services list or picker, then reuse it with “Post my morning routine to my Reddit profile using the new service.” Verify the published post after approved execution; use only an explicitly authorized demo account and target. Preserve approval requirements in the created service. Verify that it was absent before, created during this run, and usable afterward. Opening a preinstalled Reddit service is not this scene.
4. Keep the website use, creation, and reusable result understandable in the cut. Trim waiting time if needed, but do not replace service creation with a replayed assistant claim. Report any authentication or authoring limit rather than implying success.

## Review and deliver

- Review all footage for identifying details in chats, memory, emails, repositories, account menus, provider settings, and Reddit. Redact response copies before loading the replay server; keep real source transcripts private. Avoid opening account identifiers during a take.
- Verify all three headings, all three exact Connect anything prompts, their assigned chips, the first reply, and typing-only planning/publishing scenes. Verify the visible airplane-mode action, radios off, a new offline reply, the model-provider list, and actual Reddit service creation and reuse.
- For variable-frame-rate captures, trim by source timestamps before constant-frame-rate conversion, then trim to intended duration again: the last retained frame can otherwise hold until the next source frame. Do not assign sequential frames new 30 fps timestamps, which speeds up cursor blinking. If a still screen stops producing frames, create a later frame by opening and dismissing **More**, then trim before that menu.
- Review each changed scene and final joins. Confirm replies are complete and chapter transitions are clear. Do not mark an unverified or blocked chapter as finished.
- Deliver the recording without composited cards or overlays. Report the output path, actual model used, and any service limits. For explicitly requested replay, disclose the saved response source and distinguish it from live footage. Share screenshots or representative frames for human review.

## Publish on openox.ai

Use this flow only when the user asks to publish the finished demo on the website.

1. Work in the adjacent `openox-dev` checkout and follow its `AGENTS.md`. Keep the source recording and encoded video outside tracked website files. Use its ignored `.work/media/` directory for staging.
2. Convert the portrait source to a browser-compatible H.264 MP4 with `yuv420p`, `+faststart`, and no audio when the recording is silent. Use 1080 × 1920 for a 9:16 source. Decode the complete result with `ffmpeg -v error -i <encoded.mp4> -f null -` and inspect its codec, dimensions, and duration with `ffprobe`.
3. Name the asset with a stable content-derived suffix and propose its final URL before upload: `https://openox.ai/assets/media/ox-demo-<suffix>.mp4`. Do not upload until the user approves that path.
4. Keep the MP4 out of Git. A small reviewed poster image may live in `openox-dev/web/assets/`. Reference the video from a native `<video controls playsinline preload="none">` element. Keep its layout responsive at 9:16.
5. Confirm the `Ox-Web` CloudFront distribution routes `/assets/media/*` to the retained `openox-service-assets-prod` bucket. Reuse the existing service-assets origin. Run `bun run typecheck` and inspect `bun run cdk diff Ox-Web` before deployment.
6. Upload the approved file to `s3://openox-service-assets-prod/assets/media/<filename>` with `Content-Type: video/mp4` and `Cache-Control: public,max-age=31536000,immutable`. Then deploy `Ox-Web` from `openox-dev/cdk`.
7. Verify the public page, poster, and video return successfully. Confirm the live MP4 checksum matches the staged file and a byte-range request returns `206`, which verifies seeking through CloudFront. Confirm no video file is tracked by Git.
