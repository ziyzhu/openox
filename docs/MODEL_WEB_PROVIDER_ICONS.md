# Model website service icons

Audited on 2026-09-25 for ten current and planned model website services. ChatGPT's ordinary web service already uses the built-in asset URL and its existing icon passes the same size and safe-area checks.

Built-in manifests omit `faviconUrl` so `packages/services/src/service.ts` generates `https://openox.ai/assets/services/<domain>/favicon.png` from the reviewed `favicon.png`. This is the OpenOx CloudFront asset path. Source artwork URLs below are provenance, not runtime dependencies. The model provider picker renders web providers through `ServiceAvatar`, using the resolved service icon and its shared loading/cache behavior. Local user-authored services may still use their verified public icon URLs.

| Service | Official artwork source |
| --- | --- |
| Claude (`claude.ai`) | [Publisher's App Store listing](https://apps.apple.com/us/app/claude/id6473753684); [source artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/24/ff/cb/24ffcb56-9d47-60cc-266c-fcb43e31a190/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg) |
| Doubao (`doubao.com`) | [Publisher's App Store listing](https://apps.apple.com/cn/app/id6459478672); [source artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/a8/2c/8a/a82c8ab3-4f8a-cf8a-d295-a5cf32c2688a/AppIcon-0-0-1x_U007epad-0-8-0-sRGB-85-220.png/512x512bb.jpg) |
| Gemini (`gemini.google.com`) | [Publisher's App Store listing](https://apps.apple.com/us/app/google-gemini/id6477489729); [source artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/7b/b1/22/7bb122bd-3f0a-2663-88ec-c3c6d32ee880/AppIcon-0-0-1x_U007epad-0-0-0-1-0-0-sRGB-0-0-85-220.png/512x512bb.jpg) |
| Qwen (`qwen.ai`) | [Publisher's App Store listing](https://apps.apple.com/id/app/qwen-alibaba-ai-assistant/id6757738627); [source artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/2e/36/e6/2e36e6cd-563c-96d5-a3c7-66deea418f79/AppIcon-0-0-1x_U007epad-0-1-0-85-220.png/512x512bb.jpg) |
| Microsoft Copilot (`copilot.com`) | [Publisher's App Store listing](https://apps.apple.com/us/app/microsoft-copilot/id541164041); [source artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/69/94/ed/6994ed6d-80ae-35ff-3451-b9d8b81412b4/AppIcon-0-0-1x_U007epad-0-1-0-0-sRGB-0-85-220.png/512x512bb.jpg) |
| Kimi (`www.kimi.com`) | Official website icon; [source artwork](https://www.kimi.com/pwa-192.png) |
| Grok (`grok.com`) | Official website icon; [source artwork](https://grok.com/images/apple-touch-icon.png) |
| DeepSeek (`chat.deepseek.com`) | Official website icon; [source artwork](https://fe-static.deepseek.com/chat/icon-180.png) |
| Perplexity (`www.perplexity.ai`) | Official website icon; [source artwork](https://www.perplexity.ai/apple-touch-icon.png) |
| Z.ai (`chat.z.ai`) | Official website icon; [source artwork](https://z-cdn.chatglm.cn/z-ai/static/logo.svg) |

Claude, Doubao, Gemini, Qwen, and Copilot use publisher-supplied 512×512 App Store artwork because their website marks did not meet the opaque-center requirement. Z.ai uses its official SVG rasterized to PNG instead of Google's favicon cache. Other sources are official square raster icons at least 128×128. No artwork is reconstructed or raster source upscaled.

All ten stored icons pass the existing `favicon-128.sh` and `favicon-audit.sh` checks: 128×128 PNG, an opaque central 96×96 area, less than 1 MiB, and recognizable at 20 px on light and dark backgrounds. PNG sources stay in the source repository; generated runtime bundles contain only their public URLs.

When refreshing an icon, fetch and audit its official source with the scripts under `.agents/skills/promote-web-service/scripts`, deploy it through the existing service-assets workflow with an explicit OpenOx checkout, invalidate the affected CloudFront path, and verify an anonymous non-redirecting HTTPS response with PNG content type and bytes matching the source. Rebuild the services bundle after changing manifests.

Deployment verification returned anonymous HTTP 200 `image/png` responses without redirects for all ten OpenOx URLs; every response matched its checked-in PNG byte for byte. The targeted CloudFront invalidation completed. The services bundle rebuild, typecheck, and 20 repository/model-contract tests passed. An iOS 26.5 build on `ox-qa-2` displayed the new Claude, Gemini, Grok, and Qwen icons in the Global provider picker. Light/dark artwork checks used the audit previews; the app retained its light appearance during the simulator check.

Native API and subscription-provider icons, including GitHub Copilot, are audited separately in [Model provider icons](MODEL_PROVIDER_ICONS.md).
