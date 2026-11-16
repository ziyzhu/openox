---
name: authentication
description: "Use to sign in to a website, connect a website account, or recover authentication needed for a service task, including missing login support. Model-provider credentials use the native provider authentication flow instead."
---

# Authentication

Establish the intended website account, let the user complete human steps on the live page, then verify fresh destination authentication before resuming the original request. Preserve existing sessions, tenant context, return paths, and runtime approvals. Never sign out, clear website data, or switch accounts merely to test login. Pages share website data; a new page does not isolate accounts.

## Prepare

Inspect the destination service and reuse its standard login and listSessions contracts. Open or reuse an owned page at an observed entry point; never guess a login path. Discover live frames and invoke the service matching the selected frame's origin with its explicit frameId. Check listSessions on the intended destination context first. Reuse an authenticated account that matches the request; ask when account or tenant selection is ambiguous. An error or unknown state is not proof the user is signed out.

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

## Advance and hand off

Invoke the matching service's login action on the live frame. Login prepares or advances one step in the background; its acknowledgment does not establish authentication or present a page. Use returned page.frames and page.document first. If observation is absent, loading, truncated, or insufficient, discover fresh frames and inspect the relevant document with browser.snapshot. A URL, title, or nonblank page alone does not establish readiness. After navigation, discover fresh frames and inspect the new document. Keep the same owning page through redirects and embedded provider flows; never copy authorization URLs into another page.

Continue automatic steps only when fresh evidence establishes a new supported screen. Stop automatic advancement on unchanged screens, rejected credentials, errors, or ambiguous identity. For MFA, bot verification, passkey, consent, or a manual sign-in step, establish that the intended screen is human-readable with legible content and usable controls; disclose when readability cannot be verified. Explain what the user needs to do, then call `await ox.web.browser.showPage({ purpose, pageId })` with that exact owning pageId. Never bypass challenges, request their answers or tokens, or replay login to recover presentation.

The call asynchronously waits for Done/Cancel and returns only { status: "completed" } or { status: "cancelled" } in the same execution and turn. Do not poll or continue dependent work while waiting. On cancelled, stop dependent work and do not reopen automatically. On completed, inspect fresh state; Done acknowledges interaction, not successful sign-in.

## Diagnose failures

| Fresh evidence | Next action |
| --- | --- |
| Wrong selector, unsupported observed screen, or other confirmed handler defect | Stop automatic attempts and use Evolve to repair support. Use existing structural diagnostics and read-only inspection; preserve the page. If manual sign-in is needed to gather missing evidence, present it and complete the repair afterward. |
| Password or code rejected, account locked, or rate limited | Do not resubmit or edit the handler to bypass rejection. Explain the observed problem. If the user chooses to correct credentials or recover the account, present the preserved page for that manual attempt. |
| MFA, captcha, bot verification, passkey, or consent | Present the exact live page and await the user. These are human steps, not evidence of broken automation. |
| Timeout, network error, stale frame, or unchanged screen without a known cause | Inspect fresh page and session state before classifying. Rediscover stale frames without replaying submission. Repair only a confirmed implementation defect; report unresolved runtime or network blockers. |
| Done but destination still signed out or wrong account | Do not claim success or run protected work. Explain the observed state and ask whether to continue manually; present the page if the user chooses another attempt. |
| Cancel, denied approval, or failed presentation | Stop dependent work. Preserve the page and report the outcome; never automatically reopen or replay login. |

Repairing automatic login does not authorize using a real account as a test fixture. Dry-run screen classification without retrieving or submitting credentials. Verify a repaired automatic submission only once with a dedicated user-saved test account and explicit consent, as described in Evolve's authentication reference; otherwise report the repair as unverified. Never request a sign-out or repeated credential submission just to improve diagnostics. The Host may offer to remember credentials after Done; saved credentials and structural traces are not returned to the agent as values.

## Verify and resume

Discover fresh destination frames and invoke destination listSessions. Verify the intended account and tenant, then pass its real descriptor as session when resuming protected actions. Provider authentication, cookie presence, remembered accounts, URLs, and cached service login fields do not prove destination access. Never fabricate a session descriptor or silently substitute another account.

After successful sign-in, continue the original task without an extra proposal checkpoint. Inspect current task state before retrying an interrupted mutation; login does not authorize repeating completed effects, payment, or unrelated account changes. If authentication remains unverified, report the concrete blocker without claiming success or repeatedly reopening sign-in.

For model-provider API keys, subscription credentials, bearer tokens, or OAuth, use `ox.provider.authenticate({ purpose, id })` with an existing provider ID instead of website login or ox.secret.add. Credentials remain in the native flow; authentication readiness does not prove live inference. Read `skills/evolve/SKILL.md` and its provider reference when provider configuration needs repair.
