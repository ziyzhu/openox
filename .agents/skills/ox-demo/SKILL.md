---
name: ox-demo
description: Prepare and record the Ox iOS services demo with three chats and three short prompts. Use when recording, recreating, or preparing this specific demo.
---

# Ox Demo

Use the `sim-cli` skill for visible iOS interaction and the `ox-cli` skill to verify the selected chat, model, and completed replies. Follow the repository's simulator and server rules. Keep recordings and response drafts outside the repository.

## Prepare

1. Reuse a healthy repository server or start one, and verify `/health` before simulator interaction. Use the requested simulator, normally `ox-qa-1`, and confirm the existing Ox app is ready.
2. Reuse prepared empty chats when their service attachments match; create missing chats as needed. Attach Amazon, Facebook, and Reddit to the desk chat; Airbnb, Google, and Xiaohongshu to the Seattle chat; Outlook, LinkedIn, and 1Point3Acres to the catch-up chat. Each chat has three services, with nine distinct services across the demo.
3. Start `bun run .agents/skills/ox-demo/scripts/replay-server.ts --responses <sanitized-response-directory> --port 8082` and verify `http://127.0.0.1:8082/health`. The directory must contain `01-desks.md`, `02-seattle.md`, and `03-catch-up.md`, each prepared from a saved GPT-5.6 Luna · Fast response with private details removed. The replay server exposes `Bonsai 2 27B` as a local OpenAI-compatible model. In Ox, configure its custom provider URL as `http://127.0.0.1:8082/v1`, select that model, and tap **Save**. Verify the chat header shows Bonsai. Disclose outside the recording that the replayed answers were prepared with Luna.
4. Check service sign-in states before recording. If an attached service cannot be used, report the limit and avoid presenting its reply as a successful service result.

## Iterate efficiently

- Reuse sanitized response files, the configured provider, and a healthy replay server when they match the requested demo. Check existing state before repeating setup.
- Keep a small run manifest outside the repository with the simulator, chat IDs, response directory, raw scene paths, source trim timestamps, and final export command. Preserve each scene separately so later edits can reuse verified footage.
- Before a full take, capture and review a short sample covering typing, cursor blinking, Send, and keyboard dismissal. Check that the text and composer move together and that export timing matches the source. If the sample can serve as the finished scene, reuse it.
- For a revision, record only scenes whose visible content changed. For a timing or trimming correction, re-export from the existing raw capture. Verify changed scenes and the final joins without repeating completed setup or unrelated checks.
- Trim using source timestamps, reset each trimmed clip to start at zero, and only then convert to a constant frame rate. Preserve pauses and cursor cadence on the first export.
- For a commit-only follow-up, review the current diff, complete repository-required commit checks, and commit. Reuse completed demo validation unless the files changed in a way that invalidates it.

## Record

1. Begin with the desk chat showing its three service chips. Move to a fresh chat for each later prompt, with only its assigned three chips. The earlier eight-chip swipe sequence does not apply to this three-chat version.
2. Type and send these prompts in order:
   - “Find a desk people love and add the best deal to my cart.”
   - “Plan a Seattle weekend for me.”
   - “What should I catch up on?”
3. Attaching services through the composer's service picker can leave a leading space, so confirm the composer is empty before recording. Focus the composer with a brief tap, without pressing and holding or selecting text. Type each complete prompt in one input action. Send only after the field exactly matches the prompt; a mismatched send creates a chat the replay server rejects. Verify the completed field and hold it on screen for about one second before tapping Send or ending a typing-only scene. Cut around paste menus, autocorrect flashes, and any unsynchronized keyboard dismissal and composer movement. In the final cut, show the first prompt's reply, cutting from the completed prompt directly to the anchored message so the send animation is skipped. Match the reference pace: about 0.9 seconds of empty composer before typing, about 1.1 seconds on the completed desk prompt, the reply stream plus about 0.6 seconds, and about 1.5 to 1.7 seconds on each later completed prompt. End the Seattle and catch-up scenes on their completed typed prompts, before either agent reply appears.
4. Record the simulator with `sim --device <device> record-video start --out <path.mov>` and `sim --device <device> record-video stop`. Send one prompt in each chat and let its saved response finish in Ox before continuing. On `ox-qa`, a still screen may not extend the recording after the last streamed frame. Open and dismiss **More** after completion to create a later frame, then trim the clip before the menu. Trim variable-frame-rate captures by source timestamps before converting to a constant frame rate, then trim again to the intended duration because the last kept frame otherwise holds until the next source frame; assigning sequential frames new 30 fps timestamps speeds up the cursor blink. Verify the exported first reply is complete and the second and third clips contain only typing. Join the simulator clips without overlays. The replay server rejects other prompts rather than inventing answers.

## Review and deliver

- Save each pre-run reply outside the repository. Remove personal names, account addresses, and other identifying details from shared response copies.
- Review the simulator recording for identifying details in the live UI. Redact the saved response text before loading the replay server; the chat transcript receives the redacted text.
- Verify that the video shows three distinct chats with their assigned service chips, the requested model, each exact prompt, and public inline links in the first reply. The second and third chats should show only typing. Disclose the prerecorded Luna source when sharing the recording.
- Deliver the simulator recording without composited cards or overlays. Report the output path and any service limits visible in the recording.

## Publish on openox.ai

Use this flow only when the user asks to publish the finished demo on the website.

1. Work in the adjacent `openox-dev` checkout and follow its `AGENTS.md`. Keep the source recording and encoded video outside tracked website files. Use its ignored `.work/media/` directory for staging.
2. Convert the portrait source to a browser-compatible H.264 MP4 with `yuv420p`, `+faststart`, and no audio when the recording is silent. Use 1080 × 1920 for a 9:16 source. Decode the complete result with `ffmpeg -v error -i <encoded.mp4> -f null -` and inspect its codec, dimensions, and duration with `ffprobe`.
3. Name the asset with a stable content-derived suffix and propose its final URL before upload: `https://openox.ai/assets/media/ox-demo-<suffix>.mp4`. Do not upload until the user approves that path.
4. Keep the MP4 out of Git. A small reviewed poster image may live in `openox-dev/web/assets/`. Reference the video from a native `<video controls playsinline preload="none">` element. Keep its layout responsive at 9:16.
5. Confirm the `Ox-Web` CloudFront distribution routes `/assets/media/*` to the retained `openox-service-assets-prod` bucket. Reuse the existing service-assets origin. Run `bun run typecheck` and inspect `bun run cdk diff Ox-Web` before deployment.
6. Upload the approved file to `s3://openox-service-assets-prod/assets/media/<filename>` with `Content-Type: video/mp4` and `Cache-Control: public,max-age=31536000,immutable`. Then deploy `Ox-Web` from `openox-dev/cdk`.
7. Verify the public page, poster, and video return successfully. Confirm the live MP4 checksum matches the staged file and a byte-range request returns `206`, which verifies seeking through CloudFront. Confirm no video file is tracked by Git.
