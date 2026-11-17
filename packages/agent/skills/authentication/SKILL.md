---
name: authentication
description: "Use to establish or recover service access: website sign-in and accounts, API credentials, MCP authorization, and iOS permissions, including missing or defective authentication support. Model-provider credentials use the native provider authentication flow instead."
---

# Authentication

Establish the access needed for the original request, verify it through the service's own contracts, then resume the task. Preserve accounts, existing sessions, tenant context, and runtime approvals. Never request passwords, codes, tokens, or API keys in chat, source, or files; credential values stay in Host-managed interfaces. Do not sign out, revoke access, clear data, or switch accounts merely to test authentication. Honor cancellation and denied approvals without reopening automatically. Inspect current task state before retrying an interrupted mutation; completing setup does not authorize replaying uncertain effects.

## Choose the service flow

Use the known service kind and canonical domain, inspecting only when contracts or identity are missing. Invoke standard actions through `ox.service.invoke({ purpose, name, input: {} })`; their complete contracts are supplied upfront. Only web services require a live frameId and support website session descriptors. Non-web setup uses the Host's native interface, not Browser or website login. Attaching a service adds its conversation chip but does not authenticate it or grant permissions; inspection and invocation do not require attachment.

| Kind | Check when access needs diagnosis | Establish access |
| --- | --- | --- |
| web | `web:<domain>:listSessions` on the destination frame | `web:<domain>:login`, then the website flow below |
| api | `api:<service>:credentialStatus` | `api:<service>:configureCredentials` |
| mcp | `mcp:<server>:connectionStatus` | `mcp:<server>:authorize` |
| ios | `ios:<app>:permissionStatus` | `ios:<app>:requestPermission` |

Reuse existing access that fits the request; do not add status checks before every working action. An error or unknown state does not establish missing credentials. Public access reported as notRequired needs no setup. Request only the access needed for the task. Missing or defective web/API implementations use `skills/evolve/SKILL.md`; MCP and iOS implementations are not editable, so report concrete blockers rather than authoring replacement authentication handlers.

## API credentials

`credentialStatus` reads local configuration without contacting the API. A configured result does not prove the server accepts the credentials. When setup is needed, explain the step and await `configureCredentials` with empty input; the Host owns API-key, HTTP basic/bearer, and supported OAuth entry and token handling. Never supply credential values or website session descriptors as action input. OAuth must use an existing client registered as OpenOx; use Evolve's API-service reference for missing or incorrect public configuration.

After configuration, verify a bounded authenticated read needed by the task, using the intended account or tenant when the API exposes it. If no suitable read exists, report configuration as complete but server access as unverified. Treat rejected credentials, insufficient scopes, wrong accounts, and network errors according to observed evidence; do not repeatedly reopen setup or weaken authentication to pass a check. A changed base URL or auth configuration requires setup again.

## MCP authorization

`connectionStatus` and `authorize` accept empty input and remain available before tool discovery succeeds. For a known saved server, call them directly when discovery is blocked by authorization; do not require successful inspection first. Connectivity failures do not establish missing authorization or an empty tool catalog. When authorization is needed, explain the step and await the Host's supported `authorize` flow. Do not move authorization URLs to Browser, collect tokens, or invent unsupported login methods.

After authorization, inspect the server's tools and perform a bounded read needed by the task when available. An authorized or notRequired result establishes connection readiness, not permission for every tool or verified task completion. Preserve the chosen server and account; report discovery, scope, transport, or unsupported-authorization blockers without silently substituting another service.

## iOS permissions

`permissionStatus` reads OS permission state without prompting. On authorizationRequired, explain why access is needed and await `requestPermission` through the Host. On denied, explain the required app permission in system Settings if the user wants to proceed; do not repeatedly request access or claim the agent changed Settings. Recheck state after the user changes it. OS permission is separate from account authentication and runtime Action approval.

After access is granted, verify the task's bounded read when one is available. Request only the relevant service's permission; do not create or send data to test access. Report denied, restricted, or unsupported capabilities accurately and stop dependent work when access remains unavailable.

## Prepare website sign-in

Pages share website data; a new page does not isolate accounts. Inspect the destination service and reuse its standard login and listSessions contracts. Open or reuse an owned page at an observed entry point; never guess a login path. Discover live frames and invoke the service matching the selected frame's origin with its explicit frameId. Check listSessions on the intended destination context first. Reuse an authenticated account that matches the request; ask when account or tenant selection is ambiguous. An error or unknown state is not proof the user is signed out.

Explain sign-in before starting. Use inspect's advertised auth methods, copying the chosen item unchanged into login input.auth. When saved accounts exist and the user has not named one, ask with ox.user.choose, offering display names and Sign in manually even for one account. Filter saved secrets to type account and pass only the selected reference as input.account: { $secret, serviceID }. Never request passwords, codes, tokens, or API keys in chat, or retrieve credential field values through Browser.

Honor the user's chosen method. When multiple advertised methods remain plausible, ask rather than silently choosing another identity provider. Omitted auth metadata means unknown support; omit input.auth only for such legacy services, never invent an advertised method.

| Advertised method | Workflow |
| --- | --- |
| password | Use the selected saved account reference for supported automatic steps. With no saved account, or when the user chooses manual entry, prepare login and present the page. |
| code | Prepare the code flow and present the page for the user to request or enter the code. Never collect codes in chat or retrieve them from messages. |
| passkey | Prepare the passkey flow and present the page so the user can complete the browser or OS interaction. |
| provider | Invoke the destination login with its advertised provider item, then inspect the redirected or embedded provider frame. Inspect that provider's methods and saved-account metadata, and invoke its matching login on the fresh frame. Keep secrets with their owning service and verify the destination after return. |

Manual sign-in always requires opening the actual live webpage with showPage; telling the user to sign in, returning a URL, or opening a background page does not present it. This applies to every manual attempt, including a human step reached after automatic progress.

If login or session discovery is missing or defective, read `skills/evolve/SKILL.md`, its web-service reference, and `skills/evolve/references/web-authentication.md`. Build or repair support within the original task, preserve Local work and website state, validate, and verify through service actions. Do not leave a confirmed automatic-login defect as only a manual workaround. For an unimplemented sign-in provider, explain the limitation and offer to build it rather than connecting it unasked.

## Advance website sign-in and hand off

Invoke the matching service's login action on the live frame. Login prepares or advances one step in the background; its acknowledgment does not establish authentication or present a page. Use returned page.frames and page.document first. If observation is absent, loading, truncated, or insufficient, discover fresh frames and inspect the relevant document with browser.snapshot. A URL, title, or nonblank page alone does not establish readiness. After navigation, discover fresh frames and inspect the new document. Keep the same owning page through redirects and embedded provider flows; never copy authorization URLs into another page.

Continue automatic steps only when fresh evidence establishes a new supported screen. Stop automatic advancement on unchanged screens, rejected credentials, errors, or ambiguous identity. For MFA, bot verification, passkey, consent, or a manual sign-in step, inspect the intended live screen and disclose when it appears blank or usable controls cannot be verified. Present the exact page even with that uncertainty so the user can inspect or complete the step. Explain what the user needs to do, then call `await ox.web.browser.showPage({ purpose, pageId })` with that exact owning pageId. Never bypass challenges, request their answers or tokens, or replay login to recover presentation.

The call asynchronously waits for Done/Cancel and returns only { status: "completed" } or { status: "cancelled" } in the same execution and turn. Do not poll or continue dependent work while waiting. On cancelled, stop dependent work and do not reopen automatically. On completed, immediately call browser.frames on the same pageId and inspect the current document with its fresh frameId before replying or ending the turn. Discard pre-handoff frame IDs and blocker assessments. Verify sign-in and continue the original task when unblocked; report a remaining blocker only from fresh evidence. Do not wait for the user to announce completion again. Done acknowledges interaction, not successful sign-in.

## Diagnose website failures

| Fresh evidence | Next action |
| --- | --- |
| Wrong selector, unsupported observed screen, or other confirmed handler defect | Stop automatic attempts and use Evolve to repair support. Use existing structural diagnostics and read-only inspection; preserve the page. If manual sign-in is needed to gather missing evidence, present it and complete the repair afterward. |
| Password or code rejected, account locked, or rate limited | Do not resubmit or edit the handler to bypass rejection. Explain the observed problem. If the user chooses to correct credentials or recover the account, present the preserved page for that manual attempt. |
| MFA, captcha, bot verification, passkey, or consent | Present the exact live page and await the user. These are human steps, not evidence of broken automation. |
| Timeout, network error, stale frame, or unchanged screen without a known cause | Inspect fresh page and session state before classifying. Rediscover stale frames without replaying submission. Repair only a confirmed implementation defect; report unresolved runtime or network blockers. |
| Done but destination still signed out or wrong account | Do not claim success or run protected work. Explain the observed state and ask whether to continue manually; present the page if the user chooses another attempt. |
| Cancel, denied approval, or failed presentation | Stop dependent work. Preserve the page and report the outcome; never automatically reopen or replay login. |

Repairing automatic login does not authorize using a real account as a test fixture. Dry-run screen classification without retrieving or submitting credentials. Verify a repaired automatic submission only once with a dedicated user-saved test account and explicit consent, as described in Evolve's authentication reference; otherwise report the repair as unverified. Never request a sign-out or repeated credential submission just to improve diagnostics. The Host may offer to remember credentials after Done; saved credentials and structural traces are not returned to the agent as values.

## Verify website sign-in and resume

Discover fresh destination frames and invoke destination listSessions. Verify the intended account and tenant, then pass its real descriptor as session when resuming protected actions. Provider authentication, cookie presence, remembered accounts, URLs, and cached service login fields do not prove destination access. Never fabricate a session descriptor or silently substitute another account.

After successful sign-in, continue the original task without an extra proposal checkpoint. Inspect current task state before retrying an interrupted mutation; login does not authorize repeating completed effects, payment, or unrelated account changes. If authentication remains unverified, report the concrete blocker without claiming success or repeatedly reopening sign-in.

## Model-provider credentials

For model-provider API keys, subscription credentials, bearer tokens, or OAuth, use `ox.provider.authenticate({ purpose, id })` with an existing provider ID instead of website login or ox.secret.add. Credentials remain in the native flow; authentication readiness does not prove live inference. Read `skills/evolve/SKILL.md` and its provider reference when provider configuration needs repair.
