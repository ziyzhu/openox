# Ox repository index site

Status: pages and API run locally in `openox-dev` with `bun run dev:repositories`, using a JSON file for the table, a log file for email, and local sign-in. Not built: CDK stack, DynamoDB, Lambda entry point, SES, CloudFront routing, the Built-in entry, and the reachability check. Google sign-in is written but has never run. Nothing is deployed.

## Goal

Publish a reviewed index of Ox repositories at `openox.ai/repositories`. Anyone can browse repositories, their services, skills, and action details. Signed-in users register a repository pinned to a commit hash and update the pin through the same view. Every registration and update requires review before it is listed.

Implementation lives in `openox-dev`. This repository changes only if the app later installs by pinned commit or links to the index.

## Ox repository

A Git repository with a root `repository.json` (schema v3, `packages/protocol/src/repository.ts`) declaring `name`, `services`, and `skills`, each capped at 256.

- Services are `<kind>:<domain>` with kind `web`, `api`, `ios`, or `mcp`, stored at `<kind>/<domain>/service.json`. `web` and `api` services also carry `actions.js`.
- Each `web` or `api` action declares `id`, `label`, `description`, `inputSchema`, `outputSchema`, `requireAuth`, `requireApproval`, and `defaultArgs`.
- `mcp` manifests hold only `id`, `name`, `description`, `endpoint`, and `transport`; tools are discovered when Ox connects.
- Skills live at `skills/<name>/SKILL.md` with `name`, `description`, and optional `services` frontmatter.
- `ox --repository <git-url> repository verify` validates this layout today.

## Architecture

```diff
 openox-dev/
   cdk/lib/
+    repositories-stack.ts     table, Lambda, Function URL, secrets
     web-stack.ts              /api/* behavior and page routes
+  api/                        handlers, Git and identity providers, local server
   web/
+    repositories.html         browse and detail
+    repositories-submit.html  register, update, status
+    repositories-review.html  review queue
+    repositories.js
+    assets/fonts/             self-hosted pixel font
+  tailwind.css                source for the generated web/site.css
```

- One Lambda behind the existing CloudFront distribution at `/api/*`, same origin as the pages.
- The production Content Security Policy stays unchanged: no inline scripts or styles, no third-party images, and `form-action 'none'`, so pages submit with `fetch`.
- The Lambda validates manifests with schemas vendored from a recorded OpenOx revision. OpenOx never depends on `openox-dev`.
- Repository content is read through a Git provider adapter chosen by the origin's host. GitHub is the only adapter in v1.

## Git providers

A Git provider is where a repository is hosted. It is independent of the identity provider used to sign in: a Google user can register a GitHub repository.

Each adapter implements the same operations, and nothing outside the adapter knows a provider's URLs or API:

```text
normalize(url)             -> canonical origin, or reject
resolveDefaultBranch(o)    -> full commit hash of the default branch tip
isOnDefaultBranch(o, c)    -> whether the commit is reachable from the default branch
readFile(o, c, path)       -> bytes, or not found
sourceUrl(o, c, path)      -> link to a file at a commit
compareUrl(o, from, to)    -> link to a comparison between two commits
```

- A fixed registry maps hosts to adapters: `github.com` in v1. An origin whose host is not registered is rejected at check with a message naming the supported providers.
- The origin key already starts with the host, so the provider is derived from it and not stored.
- Canonical origins are `<host>/<owner>/<name>`, lowercased, without `.git`, credentials, query, or trailing slash, so one repository cannot be registered twice under different spellings.
- Only public repositories are accepted. Adapters read anonymously or with a site-owned credential, never with a user's token.
- Validation reads `repository.json` and then only the paths it declares, so adapters need no directory listing or Git protocol support.
- API responses carry `sourceUrl` and `compareUrl` values, so pages never build provider URLs.
- Adding a provider means one adapter and one registry entry. Table, API, pages, and review are unchanged.

GitHub adapter:

- Reads files from `raw.githubusercontent.com/<owner>/<name>/<commit>/<path>`.
- Resolves the default branch and checks reachability through the REST API, authenticated with a site-owned credential in Secrets Manager; anonymous calls are limited per IP address, which Lambda shares.
- Requires the commit to be on the default branch. GitHub serves commits from forks under the parent repository's URLs, so reachability by URL alone does not prove the commit belongs to the repository.
- Uses the canonical owner and name returned by the API, so a renamed repository normalizes to its current origin.

## Built-in repository

The repository included with Ox is listed first on the browse page, so the index shows everything Ox can do, not only what can be added.

- Its source is `apps/shared/Resources/OxServices.bundle` in the public `github.com/ziyzhu/openox` repository: a valid `repository.json` named `Built-in`.
- It is a configured entry of origin, root path, and commit, not a table item. It has no owner, review, or notifications, and its origin cannot be registered by anyone.
- The commit is the recorded OpenOx revision that `openox-dev` already consumes for the vendored schemas, changed by a reviewed deployment. It should match the current App Store release.
- It reads through the same GitHub adapter; the root path is a prefix on every file read and source link. Registered repositories always use the repository root.
- It renders with the same detail and action views, marked "Included with Ox", with no install control. The manifest lists both bundled services and System skills; the site counts and displays both.
- Its service icons are already served from `openox.ai/assets/services/`, so they display under the existing Content Security Policy.
- With about 90 services, its list entry carries counts only; services load with the detail view.

## Storage

Git at the pinned commit is the source of truth for names, services, skills, and actions. DynamoDB stores only what Git cannot answer. One table, `openox-repositories`, one item per repository, no indexes.

```text
PK=<origin>     github.com/ziyzhu/ox-services
  owner         <idp>:<subject>
  email         owner's verified address, refreshed at each sign-in that submits
  published     <commit>                               absent until first approval
  review        { commit, state: pending|rejected, note? }   absent when nothing is in review
  delisted      true                                   absent while listed
```

- The normalized origin is the key, which prevents duplicate registrations.
- Approval moves `review.commit` to `published` and removes `review`. The previous pin stays live while an update is in review.
- Review history lives in structured Lambda logs, not rows.
- The review queue and "my repositories" are filtered scans.
- No users, sessions, or snapshots are stored. The owner's email is the only personal data, kept on the repository item for notifications and removed with it.

## Commit hash

- Call the pin a commit hash everywhere; `repository.json` already uses `contentHash` for a different SHA-256 value.
- Accept only a full hash of 40 or 64 hexadecimal characters. Reject branches, tags, and abbreviated hashes.
- "Use latest commit" resolves the default branch tip to a full hash before submission.
- Display the abbreviated form and link the full hash to the source.

## Authentication

- Provider-neutral OAuth authorization-code flow handled by the Lambda: `/api/auth/<idp>/start` and `/api/auth/<idp>/callback`.
- Google is the first identity provider. Adding another needs its endpoints, scopes, subject claim, and a client secret in Secrets Manager.
- Every OAuth client is registered as OpenOx.
- Identity is `<idp>:<subject>`, carried in a signed, stateless, HttpOnly session cookie.
- No account linking. A repository belongs to the identity that registered it; transfers go through the reviewer.
- Google cannot prove repository ownership, so v1 relies on first-come registration plus review. An identity provider that is also a Git provider, such as GitHub, can check push permission on its own origins when added.

## Google sign-in setup

Console steps are manual and happen once in Google Cloud, under an account owned by OpenOx.

1. Create a Google Cloud project named `OpenOx`.
2. In Google Auth Platform, Branding: set the app name to `OpenOx`, the support and developer contact emails, the logo, home page `https://openox.ai`, privacy policy `https://openox.ai/privacy`, and authorized domain `openox.ai`.
3. In Audience: choose External and publish to production. Testing mode restricts sign-in to listed test users.
4. In Data Access: request `openid` and `email` only. Both are non-sensitive, so no scope verification is needed. `email` is stored on the repository item for notifications, and only when Google reports `email_verified`.
5. Complete brand verification so the consent screen shows the OpenOx name and logo. It requires proving ownership of `openox.ai` in Search Console.
6. In Clients: create a Web application client with the single redirect URI `https://openox.ai/api/auth/google/callback`. Leave JavaScript origins empty; the flow is server-side. The other domains redirect to `openox.ai`, so they need no entries.
7. Create a second Web application client for local development with a `http://localhost` redirect URI. Never reuse the production client locally.
8. Store the production client ID and secret in Secrets Manager, alongside a separately generated session-signing key. The Lambda reads them by reference; nothing goes in source, CDK context, or command arguments.

Lambda flow:

1. `/api/auth/google/start` generates `state`, `nonce`, and a PKCE verifier, stores them in a short-lived HttpOnly cookie, and redirects to `https://accounts.google.com/o/oauth2/v2/auth` with `response_type=code`, the scopes, the redirect URI, and an `S256` code challenge.
2. `/api/auth/google/callback` rejects a missing or mismatched `state`, then exchanges the code at `https://oauth2.googleapis.com/token` with the client secret and verifier.
3. Validate the ID token: signature against Google's published keys, `iss` is `https://accounts.google.com`, `aud` is the client ID, `exp` is in the future, and `nonce` matches.
4. Take `sub` as the subject. Never key identity on `email`, which can change.
5. Set the session cookie with `Secure`, `HttpOnly`, `SameSite=Lax`, and `Path=/api`, clear the transient cookie, and redirect to `/repositories/submit`. Discard Google's access token; no refresh token is requested.
6. `/api/auth/signout` clears the session cookie.

CloudFront: the `/api/*` behavior forwards cookies and query strings, allows all methods, and disables caching for auth and signed-in routes.

Verification: sign in from a fresh browser on desktop and iPhone, confirm the consent screen shows OpenOx, and exercise denied consent, replayed or mismatched `state`, an expired code, and sign-out.

## Email notifications

Sent through Amazon SES from `repositories@openox.ai`. All messages are transactional; there is no marketing mail and no unsubscribe list.

```text
submitted or updated  -> reviewer   origin, commits, link to the review page
submitted or updated  -> owner      confirmation that review is pending
approved              -> owner      listed commit and link to the repository page
rejected              -> owner      reviewer note and link to the submit page
delisted              -> owner      reason: takedown or unreachable commit
```

Setup, since `openox.ai` has no mail records today:

1. Create an SES domain identity for `openox.ai` in CDK and publish its DKIM records in the hosted zone.
2. Configure a custom MAIL FROM subdomain such as `mail.openox.ai` with its MX and SPF records, and add a DMARC record for `openox.ai`.
3. Request SES production access. A new account is sandboxed and can send only to verified addresses.
4. Set `Reply-To` to a monitored support address; `repositories@openox.ai` receives no mail.
5. Route bounces and complaints to a notification topic and stop sending to an address after a hard bounce or complaint.
6. Grant the Lambda `ses:SendEmail` restricted to this identity and sender.

Behavior:

- The reviewer address comes from configuration, not the table.
- Messages are plain text and carry only the origin, commit, state, and note. Reviewer notes are inserted as text, never as markup.
- Sending happens after the table write succeeds. A send failure is logged and does not roll back the transition; the submit page remains the source of truth for status.
- The privacy policy states that a registrant's email is stored for repository notifications and deleted with the registration.

## API

```text
GET  /api/repositories                                   listed repositories, cached 5 minutes
GET  /api/repositories/<origin>@<commit>                 repository.json and skill frontmatter, cached indefinitely
GET  /api/repositories/<origin>@<commit>/<kind>/<domain> one service manifest, cached indefinitely
POST /api/repositories/check                             validate origin and commit, persist nothing
POST /api/repositories                                   register or update, sets review to pending
GET  /api/repositories/mine                              signed-in owner's items
GET  /api/review                                         pending items, reviewer only
POST /api/review                                         approve or reject with a note
GET  /api/repositories/<origin>@<commit>/<kind>/<domain>/favicon   proxied service icon
POST /api/repositories/resolve                           default branch tip for "Use latest commit"
GET  /api/session                                        identity, reviewer flag, available providers
GET  /api/auth/<idp>/start, /api/auth/<idp>/callback     sign-in
POST /api/auth/signout                                   clear the session
```

Service icons come from each manifest's `faviconUrl`, falling back to the web service's `/favicon.ico`. They are fetched through the API because the Content Security Policy blocks third-party images; nothing is stored. The proxy accepts HTTPS image responses up to 512 KB and serves them sandboxed.

## Pages

The three repositories pages use their own arcade style built with Tailwind: pixel headings, bordered blocks, and bright accents. The rest of the site keeps `web/styles.css`. Pages are single column with equal outer padding, mobile first, light only, English only in v1, with stable identifiers on every control.

The navigation bar shows Ox and Repositories tabs on the left. The right side shows Sign in, or the signed-in email as a menu with Your repositories, Review queue for reviewers, and Sign out.

Browse at `/repositories`:

- Lists the Built-in repository first, then each registered repository with its name, origin, and service and skill counts.
- Client-side search across repository names, services, skills, and action labels.
- Selecting a repository shows its services and skills, each linked to source at the pinned commit, with a control that copies an install prompt for Ox: `Connect the Ox repository at <url>`.
- Expanding a service loads its manifest on demand and shows each action's label, description, flattened inputs, and collapsed outputs.
- `requireAuth` and `requireApproval` appear as badges on the action's title line.
- Output `$ref`s resolve one level against `$defs`; deeper schemas link to the manifest in source.
- `mcp` services show endpoint and transport with a note that tools are discovered on connection.
- Skills show their description and linked service dependencies.
- Each service shows its icon and a kind label; a letter tile stands in when no icon loads.

Submit at `/repositories/submit`:

- Signed-out visitors see the identity provider choices.
- "Your repositories" shows each item's published commit, review state, and rejection note, with an Update control.
- Register and Update share one form. Update pre-fills and locks the origin so only the commit changes.
- Check shows validation results inline. Submit is enabled only after a clean check.

Review at `/repositories/review`:

- Lists pending items with published and proposed commits and the provider's comparison link.
- Shows added and removed services and skills, and added, removed, or flag-changed actions. An action dropping `requireApproval` is highlighted.
- Approve or reject with a note. The reviewer runs `ox repository verify` manually in v1.

## State machine

```text
unregistered -> pending(first) -> listed | rejected(first)
listed -> pending(update) -> listed(new commit) | listed(old commit, rejected update)
listed -> delisted
```

## Edge cases

- Pinned commit becomes unreachable, or the repository goes private or is renamed: a periodic check delists it.
- A different identity submits a registered origin: rejected.
- A new update arrives while one is pending: it replaces the pending commit.
- Abuse: per-identity pending limit and structured logs for every transition.
- Unregistered host, private repository, or a commit not on the default branch: rejected at check.
- Git provider unavailable or rate limited with a cold cache: the page reports the failure; published pins are unaffected.
- Takedown: the reviewer delists.

## Diagnostics

Log origin, commit, identity, transition, reviewer, note, validation failures, upstream fetch failures, and email send outcomes with the SES message ID. Never log cookies, tokens, client secrets, or email addresses.

## Phases

1. Table, read API, and browse page, seeded with `ziyzhu/ox-services`.
2. Authentication, check, and the submit page.
3. Review page, SES setup, and email notifications.
4. Periodic reachability check, homepage link, and README consistency.

## Open decisions

- Whether a failing service blocks the whole submission, as built, or is listed as unavailable. `github.com/ziyzhu/my-ox` fails validation at its current tip, so it cannot be registered today; the local seed bypasses the check.
- How per-commit responses are cached. They change shape when the API changes, so an indefinite cache needs a version in the path or a short lifetime.
- How the icon proxy rejects private addresses. It checks hostnames only; a resolved-address check is needed before production.

- Whether the Built-in commit tracks the App Store release automatically, once iOS release tags exist, or stays a manual revision bump.
- Whether GitHub ships as a second identity provider in v1 to prove ownership.
- Whether Ox installs by pinned commit. It installs `HEAD` today (`Repository+Remote.swift`), so the pin means "reviewed at this commit" until that changes.
- Whether detail uses `?id=` or a path such as `/repositories/github.com/ziyzhu/ox-services`, which needs a CloudFront routing rule.
- Whether the reviewer is a single allowlisted identity.
- Which Git provider follows GitHub, and whether self-hosted instances are supported. A self-hosted host does not reveal its provider, so it would need an allowlist entry or a stored provider attribute.
