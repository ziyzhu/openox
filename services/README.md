# OpenOx Services

`@openox/services` contains the compiled, sanitized Server IR for the official services built into Ox. It contains manifests, browser action bundles, skills, and icons without raw service TypeScript or HAR captures.

The package requires Bun 1.3 or newer.

```sh
bun add @openox/services
```

Resolve the installed repository root:

```ts
import { repositoryRoot } from "@openox/services";
```

Use `repositoryRoot` anywhere Ox accepts a local service repository path.

Service authoring APIs are published separately as `@openox/service-sdk`.

## Release

Update the version in `package.json`, run `bun run build:services` from the repository root, verify with `bun run package:check`, and push a matching `services-v<version>` tag from `main`. The first release requires an interactive npm publish with two-factor authentication:

```sh
bun package-check.ts --output /tmp/openox-services-release
npm publish /tmp/openox-services-release/openox-services-0.1.0.tgz --access public
```

Subsequent releases use npm Trusted Publishing through `.github/workflows/publish-npm.yml` and the `npm-publish` environment.
