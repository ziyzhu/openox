---
name: demo
description: "Prepare, drive, and record Ox’s live job-application demo: discover a job on LinkedIn, evolve a reusable Workday service, read a résumé from connected files, fill the application, and stop before submission."
---

# Ox Job Application Demo

Focus only on this live workflow:

**LinkedIn discovery → employer’s Workday portal → reusable service creation or extension → connected résumé files → filled application → review without submission.**

The story is that Ox encounters a website capability it needs, learns to use it, and applies it to a real task using the user’s files. This is not a résumé-summary demo, mass-application tool, or claim of universal Workday support. One accurate application is the goal.

Use `ios-simulator` for visible native interaction, `ox-cli` for Host inspection and verification, and `develop-services` for the real service-authoring workflow. Read those skills before driving the demo. Follow their device ownership and authoring rules. Use the requested device; do not use the physical iPhone Host for simulator work. Keep transcripts, résumés, recordings, diagnostics, and the private run manifest outside the repository.

Do not use the former three-chapter storyboard, offline-inference scene, Reddit scene, replay server, SwiftUI fixtures, or App Store artwork workflows. Do not change public feature copy or add recording-only UI. This demo uses real model requests, website interaction, and connected files.

## Candidate and preflight

The reference conversation proposed this candidate, not a verified end-to-end demo:

- Employer: NVIDIA.
- Role: Senior Software Engineer, AI Networking, Seattle.
- Requisition: `JR2021027`.
- LinkedIn: `https://www.linkedin.com/jobs/view/senior-software-engineer-ai-networking-at-nvidia-4437322577`.
- Workday: `https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/US-WA-Seattle/Senior-Software-Engineer--AI-Networking_JR2021027-1`.

The reference found matching public listings but could not inspect the interactive Workday application because browser inspection timed out. It also could not resolve the connected Documents mount. Neither the form nor résumé access is proven. Recheck both; do not inherit a readiness claim from the transcript. The role asks for specialized experience and may not suit the applicant.

1. Confirm the role is still accepting applications. Follow LinkedIn’s actual external Apply link and verify employer, title, location, and requisition on the employer portal. An indexed result or HTTP success is insufficient. If the role is closed, inaccessible, or unsuitable, propose a replacement with matching LinkedIn and Workday listings and obtain the user’s agreement before changing the target.
2. Open the actual application flow. Resolve sign-in, account creation, verification, CAPTCHA, and required consent with the user. Workday accounts and forms are employer-specific; success on one tenant does not prove another works. Do not bypass challenges or request passwords or tokens.
3. Connect a narrow, user-approved folder containing the chosen résumé/CV and optional application-profile document. Verify filename discovery and actual file reading through the Host’s connected filesystem. Do not search unrelated personal folders. Ask which résumé to use when ambiguous. Use truthful, user-approved information; never put synthetic credentials or invented qualifications into a real employer’s system.
4. Inspect existing LinkedIn and Workday capabilities and the shared Local repository’s pending changes. Record the initial service identifiers and supported actions. Do not prebuild a missing Workday service if recording first-time creation is the point. Rehearsal may create it; subsequent footage must honestly show reuse or extension. Never delete a service to stage discovery, and inspect its source again after any sign-in handoff.
5. Use the previously requested ChatGPT GPT-6 Sol · Fast with Medium thinking (`gpt-6-sol@fast`, `medium`) unless the user chooses otherwise. Verify current availability and a harmless live reply; report a blocker rather than silently substituting a model. Provider authentication is separate from website authentication. Present model choice neutrally and record the model actually used.
6. Establish explicit approval before entering personal data or uploading a résumé. Explain that Workday may save a draft or transmit data before final submission. Preserve service Action policies; the demo does not bypass them. Merely choosing this demo does not authorize uploads, application submission, or recruiter messages.
7. Test a short native recording for legible text, stable composer input, and private-data exposure. Review exact composer text after HID entry; wait for it to settle and correct autocorrection off-camera before sending. Do not send a mismatched prompt.

Keep a private run manifest with device, Host, Profile and conversation IDs, actual model, target URLs and requisition, authentication checks, selected file paths, approval scope, initial service state, pending Local changes, saved/uploaded data, blockers, capture paths, and trim timestamps. Do not copy account identifiers, credentials, or résumé contents into shared delivery notes.

## Driving prompt

Replace the role details only after agreeing on a verified target. Keep the safety boundaries intact. Start with LinkedIn rather than giving the model the Workday URL: discovering the next website is part of the demonstration.

```text
Help me prepare—but do not submit—a real job application.

Start on LinkedIn. Find NVIDIA’s “Senior Software Engineer, AI Networking”
position in Seattle, requisition JR2021027. Read the posting and follow
its external application link to NVIDIA’s official careers website.
Confirm that the employer, title, location, and requisition match.

Use my connected filesystem to find my latest résumé/CV and relevant
application profile documents. Search filenames first, then read only
relevant files. Do not browse unrelated personal or immigration
documents. If there are multiple plausible résumés, ask which to use.

Check your existing website capabilities. If this employer’s Workday
application flow is not supported, use Evolve to build the smallest
reusable Workday service needed for this application. Inspect the real
website rather than guessing fields or endpoints. Validate and attach
the service, verify its read actions, and use it for the application,
not just a one-off browser script. Reuse or extend a suitable existing
service rather than creating a duplicate. Preserve Action policies.

Before entering personal data, tell me which files you selected and
explain that Workday may autosave information to the employer before
final submission. Ask for approval to fill the form and upload my résumé.

Fill the application using facts from my selected documents. Check the
résumé parser’s output and correct errors in employment, education,
dates, and contact details. Draft free-text answers using only supported
experience; do not invent qualifications.

Ask about required answers the documents do not establish. Do not infer
work authorization, sponsorship, demographic answers, disability or
veteran status, salary expectations, or legal attestations. Leave optional
sensitive questions unanswered unless I explicitly choose an answer.

Let me personally handle sign-in, account creation, verification,
CAPTCHA, and required consent or certification. Never request or expose
passwords or authentication tokens.

Stop at the final review page. Do not submit, accept a legal attestation,
or send a recruiter message. Show what was filled, what remains
unanswered, any qualification gaps, and what was saved or uploaded.

Give brief progress updates at LinkedIn discovery, Workday capability
creation or extension, résumé reading, and application review. Be candid
about blockers; do not simulate successful actions.
```

## Drive and record

1. Start native recording and wait for readiness before interacting. Show the prompt in normal Ox UI, then the actual LinkedIn discovery and matching employer destination. Do not substitute a search snippet for following the external application route.
2. Show Ox identifying the missing capability and invoking the normal Evolve workflow. Capture actual website inspection and reusable service creation or extension. Validate and attach the result, then show it being used for this application. A chat claim or one-off script alone is not service creation. Keep shared Local changes scoped; never include unrelated work in Save. If scoped Save is unavailable, preserve the verified draft and report the limitation.
3. Show filename discovery and reading of the approved résumé through the connected filesystem. Keep the moment focused; do not scroll through unrelated files or expose personal details for spectacle. If file access is blocked, resolve it rather than pasting résumé facts into chat and claiming filesystem access worked.
4. Preserve the approval boundary before filling or uploading. Let the user handle sign-in, unknown answers, and consent. Capture actual form population and corrections to résumé-parser output. Do not infer sensitive answers or hide unresolved required fields.
5. End on the actual review page when reachable, with a concise Ox summary of completed fields, gaps, saved/uploaded information, and the fact that nothing was submitted. Verify the form itself against the approved files; an assistant’s completion message is not evidence. If required answers or attestations block review, stop there and report a partial result instead of claiming a completed application.
6. Optionally show the generated service source and selected local files using native Files when useful to explain the result. Local services are shared, not Profile-isolated. Local files and execution do not mean offline operation: model inference and website writes use the network. Do not add a separate local-first chapter.

Keep normal production UI and approvals. Do not add overlays, simulated controls, scripted success replies, or mock website results. Trim real waiting and off-camera recovery, but retain enough of each transition to make the chain understandable. Never repeat uploads or writes just to obtain a cleaner take; inspect saved state first and reuse successful footage.

## Verify and deliver

- Verify the matching LinkedIn and employer role, the interactive application, selected résumé access, actual reusable service state, and use of that service to fill the form. Record any boundary that remains unverified.
- Compare employment, education, dates, contact details, and drafted answers against the selected documents. Confirm unknown answers remain flagged and no unsupported qualifications or legal attestations were added.
- Confirm no final submission or recruiter message occurred. Report autosaved drafts and uploaded files explicitly; “not submitted” does not mean “nothing left the device.” Ask for confirmation before any cleanup that deletes data.
- Review footage for résumé details, contact information, account menus, credentials, screening answers, and employer-side identifiers. Prefer framing that avoids private data; obtain approval for visible personal information before sharing. Keep the raw source private.
- For revisions, record only missing or changed beats. Reuse raw captures for trim/framing changes. Trim by source timestamps before constant-frame-rate conversion, verify complete decoding, and inspect representative frames and final joins for readable timing and privacy.
- Share the recording path and representative frames for visual review. State the model, target role, whether the service was created, extended, or reused, what was actually filled/saved/uploaded, and remaining blockers. Call the demo complete only when the verified flow reaches review without submission.

Do not publish footage, upload website media, submit the application, or message recruiters as part of preparation or delivery. Those require a separate explicit request.
