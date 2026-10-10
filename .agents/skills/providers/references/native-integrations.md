# Native Integrations

Read the matching provider reference before changing an integration. Verify unstable metadata against first-party sources. Provider source and catalog own executable behavior.

## API and subscription providers

Give each integration a provider-owned composition file under `apps/ios/Ox/Host/Agent/LLM/Providers`. Reuse an existing transport from `LLM/Transports`. Keep Global/China and subscription/API account boundaries explicit. When OpenOx functionality uses OAuth, use apps registered as OpenOx.

Verify request requirements, reasoning controls, intentional token caps, and adaptive-thinking/reasoning-replay wire IDs against provider documentation. Do not infer reseller availability from an upstream catalog. Check provider validation, user messages, Action results, and history together; upload success alone does not prove a model can read an attachment.

## Website services

Websites do not supply the Ox agent model. Keep website authentication, conversation submission, uploads, and completion in ordinary services authored through `evolve`. Never add a browser-backed ProviderClient or automatically forward Ox history and tool declarations to a website.

Verify fresh-page fetch and XHR, explicit prompt delivery, remote conversation/reply correlation, uncertain outcomes, and cancellation. Preserve drafts and do not retry an uncertain submission. Test signed-out/expired sessions only with synthetic fixtures or isolated sessions; unauthorized website handlers can clear live credentials. Website sessions and service sign-in remain independent of API provider credentials.

## Artwork

Built-in website services use reviewed 128×128 `assets/services/<domain>/favicon.png` sources and explicit OpenOx CloudFront `faviconUrl` values. Audit the opaque central 96×96 area and light/dark rendering at 20 px, deploy through the existing service-assets workflow, and verify the anonymous hosted bytes. Local user-authored services retain verified public icon URLs.

Native API/subscription artwork is hosted on OpenOx CloudFront; do not track source files here. Keep artwork and official provenance outside Git. Published URLs belong in provider composition and `ProviderPresentation.iconURL`. Cover regional/protocol-suffixed IDs, including Bedrock and BytePlus/Volcengine. Never upscale raster sources; document opaque white backing used for transparency.
