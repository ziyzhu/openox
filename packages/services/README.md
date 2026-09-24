# OpenOx Services

`@openox/services` contains the sanitized official services built into Ox. It contains manifests, plain-JavaScript action installers, skills, and icons without TypeScript service sources or raw HAR captures.

The authored source lives in `repositories/builtin/`. Its `repository.json`
inventories services whose individual metadata is stored in `service.json`.

```sh
bun add @openox/services
```

Resolve the installed repository root:

```js
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
