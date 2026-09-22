---
name: ox-demo
description: Prepare and record the Ox iOS demo with eight service chips and three short prompts. Use when recording, recreating, or preparing this specific services demo.
---

# Ox Demo

Use the `sim-cli` skill for visible iOS interaction and the `ox-cli` skill to verify the selected chat, model, and completed replies. Follow the repository's simulator and server rules. Keep recordings and response drafts outside the repository.

## Prepare

1. Start the repository server and verify `/health` before simulator interaction. Use the requested simulator, normally `ox-qa-1`, and confirm the existing Ox app is ready.
2. Prepare three fresh chats. Attach Amazon, Facebook, and Reddit to the desk chat; Airbnb, Google, and Xiaohongshu to the Seattle chat; Outlook, LinkedIn, and Google to the catch-up chat. Google repeats so each chat has three services while all eight requested services appear.
3. Start `bun run .agents/skills/ox-demo/scripts/replay-server.ts --responses <sanitized-response-directory> --port 8082` and verify `http://127.0.0.1:8082/health`. The directory must contain `01-desks.md`, `02-seattle.md`, and `03-catch-up.md`, each prepared from a saved GPT-5.6 Luna · Fast response with private details removed. The replay server exposes `Bonsai 2 27B` as a local OpenAI-compatible model. In Ox, configure its custom provider URL as `http://127.0.0.1:8082/v1`, select that model, and tap **Save**. Verify the chat header shows Bonsai. Disclose outside the recording that the answers are prerecorded Luna output.
4. Check service sign-in states before recording. If an attached service cannot be used, report the limit and avoid presenting its reply as a successful service result.

## Record

1. Begin with the desk chat showing its three service chips. Move to a fresh chat for each later prompt, with only its assigned three chips. The earlier eight-chip swipe sequence does not apply to this three-chat version.
2. Type and send these prompts in order:
   - “Compare desks on Facebook Marketplace, Amazon, and Reddit.”
   - “Plan a Seattle weekend with Airbnb, Google, and Xiaohongshu.”
   - “What should I catch up on in Outlook and LinkedIn?”
3. Enter each full prompt with one `sim fill --id chat.input` call and verify the field before tapping Send. Keep enough of the send and reply on screen to make the sequence clear.
4. Record the simulator with `sim --device <device> record-video start --out <path.mov>` and `sim --device <device> record-video stop`. Send one prompt in each chat and let its saved response visibly stream and finish in Ox before continuing. The replay server rejects other prompts rather than inventing answers.

## Review and deliver

- Save each pre-run reply outside the repository. Remove personal names, account addresses, and other identifying details from shared response copies.
- Review the simulator recording for identifying details in the live UI. Redact the saved response text before loading the replay server; the chat transcript receives the redacted text.
- Verify that the video shows three distinct chats with their assigned service chips, the requested model, each exact prompt, public inline links, and each corresponding streamed reply. Disclose the prerecorded Luna source when sharing the recording.
- Deliver the simulator recording without composited cards or overlays. Report the output path and any service limits visible in the recording.
