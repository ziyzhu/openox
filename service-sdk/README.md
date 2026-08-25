# OpenOx Service SDK

`@openox/service-sdk` provides the schemas, validators, action contracts, helpers, and replay tooling used to author Ox services.

The SDK requires Bun 1.3 or newer.

```sh
bun add @openox/service-sdk
```

Import explicit API surfaces:

```ts
import type { ActionInstaller } from "@openox/service-sdk/action";
import { validateServiceManifest } from "@openox/service-sdk/manifest";
import { validateRepositoryPackage } from "@openox/service-sdk/repository";
```

The official compiled service collection is published separately as `@openox/services`.

## Release

Update the version in `package.json`, verify with `bun run package:check`, and push a matching `service-sdk-v<version>` tag from `main`. The first release requires an interactive npm publish with two-factor authentication:

```sh
bun package-check.ts --output /tmp/openox-service-sdk-release
npm publish /tmp/openox-service-sdk-release/openox-service-sdk-0.1.0.tgz --access public
```

Subsequent releases use npm Trusted Publishing through `.github/workflows/publish-npm.yml` and the `npm-publish` environment.
