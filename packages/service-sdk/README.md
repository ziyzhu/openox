# OpenOx Service SDK

`@openox/service-sdk` provides the schemas, validators, action contracts, helpers, and replay tooling used by Ox services.

The SDK requires Bun 1.3 or newer.

```sh
bun add @openox/service-sdk
```

Ox-authored web services use one plain-JavaScript installer format in Local and official repositories:

```js
window.ox.install(1, ({ action, retryFetch, log, lib }) => {
  action("example", {
    async invoke(args) {
      return { value: lib.cleanText(args.value) };
    },
  });
});
```

The app injects the versioned runtime and action library before evaluating each service. The official service collection is published separately as `@openox/services`.

## Release

Update the version in `package.json`, verify with `bun run package:check`, and push a matching `service-sdk-v<version>` tag from `main`. The first release requires an interactive npm publish with two-factor authentication:

```sh
bun package-check.ts --output /tmp/openox-service-sdk-release
npm publish /tmp/openox-service-sdk-release/openox-service-sdk-0.1.0.tgz --access public
```

Subsequent releases use npm Trusted Publishing through `.github/workflows/publish-npm.yml` and the `npm-publish` environment.
