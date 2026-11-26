# Registration

For sign-in, provider frames, human handoff, and API credentials, read `skills/authentication/SKILL.md`. This reference owns new website accounts.

Create the account the original request needs on the site's own sign-up page, make it reusable through the website service, verify it, then resume the task. Account creation happens once per account, so it uses Browser and a user handoff, never a service action: do not add `register`, `signUp`, or similar actions to any service. Never request passwords, codes, tokens, or payment details in chat, source, or files. Do not sign out, clear website data, or switch accounts to make room for a new account. Honor cancellation and denied approvals without reopening automatically.

## Decide

Create an account only when the user asked for one, or confirmed after you explained that the task needs one. Name the site and the account purpose. Inspect the service for the canonical domain; reuse matching saved accounts and current sessions instead of registering when they fit. When listSessions on the destination finds an account, or inspect lists saved account secrets, ask with ox.user.choose whether to use one of them or create a new account. Pages share website data, so a new page does not isolate a second account; if the site requires signing out first, explain that and let the user decide on the page.

Request only what the task needs. Skip optional plans, add-ons, newsletters, and marketing consent unless the user asked for them. A sign-up that requires a payment method, paid plan, or trial that converts to a charge is a payable commitment: read `skills/checkout/SKILL.md` for disclosure, review, and verification before presenting it. When the goal is API access, create the website account here, then follow `skills/authentication/SKILL.md` for `configureCredentials`; the user copies keys into the Host interface, never into chat.

## Evolve the service

Registration is when the service learns the site's account surface. Read `skills/evolve/SKILL.md`, its web-service reference, and `skills/evolve/references/web-authentication.md`. Within the original task, ensure `web:<domain>` exists with listSessions and login, building or repairing support without asking permission. Implement listSessions before the handoff so it can verify the new account afterward; confirmed signed-out evidence returns `[]`. Declare manifest `auth` from the observed sign-in screen, not the sign-up form; sign-up options are not evidence of sign-in methods. Build login after the account exists, following that reference's verification limits; a handler not yet verified with a dedicated test account and explicit consent stays unverified. Preserve Local work and website state, validate, and inspect the current contracts. Do not encode the sign-up journey, entered details, or account-specific values in source, defaults, or descriptions.

## Prepare the sign-up form

Open or reuse an owned page at an observed entry point, usually the site's homepage or sign-in page; never guess a sign-up path. Discover frames, snapshot, and follow observed sign-up or create-account links with goto or non-consequential clicks through evaluate on an explicit frameId. Rediscover frames after navigation. Stop at the form or at the first screen asking for personal details, credentials, verification, consent, or payment.

When the site offers several plausible methods, such as email and password, passkey, or a provider like Continue with Google, and the user has not chosen, ask with ox.user.choose. For a provider, open its observed control and follow the provider row of `skills/authentication/SKILL.md` on the provider frame, keeping the same owning page.

Prefill non-secret fields with values the user gave in chat for this registration, such as name, email, or username, using input events on the intended form. Verify the filled values with a snapshot scoped to the form before handing off. Never enter passwords, codes, payment details, or government identifiers; never check terms, consent, or marketing boxes; never submit the form. Leave the page on the prepared form, human-readable and ready for review.

## Review and submit

The user reviews and submits on the site's page; do not request separate chat confirmation or substitute a submission through Browser. Before presenting, summarize what you filled, what remains for the user, and the site's material terms or commitments you observed. Explain the user's step: review and correct the prefilled fields, choose a password, accept the site's terms if they agree, finish any email or phone verification, submit, then tap Done; tap Cancel to stop. Call `await ox.web.browser.showPage({ purpose, pageId })` with the exact owning pageId. Present observed captcha or bot verification even if the page appears blank, disclosing that uncertainty; never bypass challenges or request their answers. Never read the user's mailbox or messages for verification codes or links, even when a mail service is attached.

The call waits for Done or Cancel and returns only `{ status: "completed" }` or `{ status: "cancelled" }` in the same execution and turn. Do not poll or continue dependent work while waiting. On cancelled, stop dependent work and do not reopen automatically. On completed, immediately call browser.frames on the same pageId and inspect the current document with its fresh frameId before replying or ending the turn. Done acknowledges interaction, not account creation.

## Verify and recover

Discover fresh destination frames and invoke listSessions. A returned session for the new account verifies registration; pass its real descriptor as session when resuming protected actions. A welcome screen, URL change, or confirmation email alone does not prove a usable account.

| Fresh evidence | Next action |
| --- | --- |
| Signed in as the new account | Continue the original task without an extra checkpoint. |
| Account created but signed out | Follow `skills/authentication/SKILL.md` to sign in. Manual sign-in there lets the Host offer to remember the new credentials; the sign-up handoff does not save them. |
| Waiting on email or phone verification | Explain the pending step. Present the preserved page again only when the user says verification is done or asks to continue. |
| Form error, taken username, or existing account | Do not resubmit. Explain the observed problem; present the page again only if the user chooses to correct it, or switch to sign-in for an existing account. |
| Captcha, consent, or another human step remains | Present the exact live page again with an explanation. |
| Unknown, unchanged, or wrong account | Do not claim success or run protected work. Report the observed state and ask how to continue. |

Never automatically resubmit a sign-up form; inspect fresh state before any retry, since a repeated submission can create duplicate accounts. Report whether the account is verified, signed in, pending verification, or unconfirmed, and whether automatic login is built and verified.
