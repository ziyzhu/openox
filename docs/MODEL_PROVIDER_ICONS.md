# Native model provider icons

Audited on 2026-09-26. The API and subscription provider picker previously loaded favicons from account-portal hosts. GitHub Copilot therefore showed GitHub's site favicon, and regional cloud products could show generic console marks.

`apps/ios/Ox/Client/UI/ProviderIcon.swift` maps all 23 built-in native provider families, including their regional and protocol-specific identities to 20 reviewed artwork assets. BytePlus ModelArk and Volcengine Ark retain separate marks selected from their regional account website. Products sharing a vendor mark reuse one hosted image. Custom providers retain their domain favicon; web model services retain their resolved `ServiceAvatar`.

The runtime URLs use `https://openox.ai/assets/services/model-providers/<asset>/favicon.png`. Source PNGs live under `assets/model-providers` outside the iOS resources, with exact source provenance in [sources.json](../assets/model-providers/sources.json). The service-assets deployment command includes these assets when given an explicit OpenOx checkout.

GitHub Copilot uses the publisher's [official VS Code extension icon](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot-chat). Bedrock uses AWS's [official architecture icon](https://aws.amazon.com/architecture/icons/). Other sources are official website touch icons, provider-owned GitHub organization avatars, or previously audited built-in service artwork. xAI's current official organization artwork reflects the [provider's documented branding update](https://x.ai/api/changelog); this icon refresh does not rename provider identities or account settings.

Every output is a 128×128 PNG below 1 MiB with an opaque central 96×96 area, visually reviewed at 20 px on light and dark backgrounds. Transparent official artwork is composited on a white tile without changing the mark; existing opaque artwork keeps its original background. Vector sources are rasterized; raster artwork is never upscaled. This normalization is recorded in the source inventory.

All 20 hosted URLs returned anonymous HTTP 200 PNG responses without redirects and matched their checked-in source bytes. The targeted CloudFront invalidation completed. Repository typechecking, provider mapping checks, and the iOS 26.5 build passed. The Global and China pickers were exercised on `ox-qa-2`, including regional providers and both Bedrock protocols; the simulator retained its original light appearance and Mock model, and its Global region was restored afterward.
