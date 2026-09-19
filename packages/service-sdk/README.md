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

## API services

API repositories use `api/<id>/service.json` and `actions.js`, listed as `api:<id>`
in `repository.json`. The manifest retains `domain` as its stable service ID,
sets `kind: "api"`, and declares an HTTPS `baseUrl` and `auth` configuration.
Supported auth types are `none`, `apiKey` (header or query), `http` (basic or bearer),
and `oauth2` (authorization code with S256 PKCE and a registered app callback).
Only public configuration belongs in the manifest; the Host stores credentials.

API installers use the same `window.ox.install(1, installer)` registration shape.
They receive `action`, `request`, `log`, and `lib.cleanText`. The asynchronous
`request({ path, method?, query?, json? })` function performs a bounded request
within the configured API base URL and returns parsed JSON. The Host injects
credentials only when the action declares `requireAuth: true`. Writes require
`requireApproval: true`; redirects and automatic retries are disabled. There is
no DOM, ambient fetch, agent bridge, or token access. Source authoring and live
verification happen inside Ox through manage-services.

Run `OX_HOST_ENDPOINT=ws://127.0.0.1:9101 bun run test:api-services` against a
running simulator Host for synthetic authentication and HTTP boundary checks.
