# Native Integrations

Read the matching provider reference before changing or reviewing an integration. Verify unstable metadata against first-party sources. Provider source and catalog own executable behavior; update references only where human-facing context is stale.

## Native API and subscription providers

Give each integration a provider-owned composition file under `apps/ios/Ox/Host/Agent/LLM/Providers`. Reuse a transport from `LLM/Transports` when its wire protocol exists. Add a focused provider reference and route it from this skill. Keep Global/China and subscription/API account boundaries explicit.

When request requirements change, verify provider documentation, including whether reasoning can be disabled. Preserve intentional token caps. Do not infer reseller availability from the upstream vendor's catalog. Adaptive-thinking and reasoning-replay lists must match wire IDs, including provider prefixes.

When OpenOx functionality uses OAuth, use apps registered as OpenOx.

## Model-capable web services

Website authentication, submission, upload, completion, and model discovery belong in `apps/ios/Ox/Resources/OxServices.bundle/web/<domain>/actions.js`. Follow the built-in `evolve` model contract and reuse `WebServiceModelProvider`; do not add a site-specific Swift composition file.

Preserve Ox's logical instructions and tools across API and website providers; optimize website delivery through verified continuation, not a reduced assistant prompt. Verify failures through the outer agent too: closing a page does not prevent its retry policy from submitting again. Keep the original failure in on-device diagnostics when surfacing an uncertain outcome.

Verify both fetch and XHR on a fresh owned generation page. A warm inspection page can use a different transport, and hidden-page animation state may lag completed server responses. Require a native completion marker correlated with the submitted conversation.

Test signed-out and expired-session behavior with synthetic fixtures or an isolated session. Do not remove authentication from a live signed-in website-client request: its unauthorized-response handler can clear the user's session even for a read-only request. Verify the signed-out-to-signed-in transition across a separate handoff page. Sign-in probes must read fresh shared state and avoid website-client handlers that clear credentials on unauthorized responses; an already authenticated page is insufficient evidence.

## Attachments

Check bundled/discovered capabilities, provider validation, user messages, Action results, and history together. Verify the model can read a synthetic image or document through the real upload path; an upload ID alone is insufficient. For composer-driven providers, reacquire the editor after file processing and verify native editor state before submission. An enabled Send button may reflect attachments while the prompt remains uncommitted. Preserve existing website drafts.

## Artwork

Built-in model web services use reviewed 128×128 `assets/services/<domain>/favicon.png` sources and explicit OpenOx CloudFront `faviconUrl` values in their manifests; replace third-party URLs. Audit the opaque central 96×96 area and light/dark rendering at 20 px, upload through the existing service-assets deployment workflow, and verify the anonymous hosted response matches the source. Use the resolved service and shared `ServiceAvatar` in the picker. Local user-authored services retain verified public icon URLs.

Native API/subscription artwork is hosted on OpenOx CloudFront; do not track its source files in this repository. Keep working artwork and official provenance outside the repository. Published URLs belong in provider Swift composition and `ProviderPresentation.iconURL`. Cover regional/protocol-suffixed IDs, including both Bedrock transports and BytePlus/Volcengine. Audit normalized 128×128 PNGs with existing favicon checks; preserve official artwork, never upscale raster sources, and document opaque white backing used for transparency.
