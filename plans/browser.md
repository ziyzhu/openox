# Ox browser plan

Goal: qualify Ox as an Apple-approved browser so users can authenticate to third-party websites with passkeys inside Ox. Keep the existing WebKit browser; establish Profile-owned website sessions through an agreed storage transition. Current website sessions are app-wide. Do not build a separate engine or custom JavaScript passkey bridge.

Status: external-link handling and selected navigation paths are implemented and simulator-verified. The audit reproduced cross-Profile cookie/local-storage sharing and a nonfunctional JavaScript popup; Profile isolation and broader compatibility remain unfinished. Apple approval and passkey behavior in an entitled Ox build remain unverified. Users should not need to select Ox as their default browser to use embedded passkeys; verify this on-device before promising support.

## Benefits and trade-offs

Benefits:
- Passkeys for third-party websites without requiring each website to authorize Ox through associated domains.
- Authentication stays inside Ox's browser and its appropriate Profile website-data store.
- System-managed credential selection and user verification; Ox does not store passkey private keys.
- Eligibility as a default-browser option and additional documented browser capabilities, including Service Workers.

Costs and limitations:
- Apple-managed entitlement approval has uncertain eligibility and timing.
- Native photo-library search and album organization are removed; user-selected photo attachments remain available.
- Native BLE/GATT device control is removed to avoid the prohibited Bluetooth permission key.
- General browsing, external-link handling, and broader compatibility testing become ongoing responsibilities.
- Passkeys still require user participation and do not resolve embedded OAuth rejection, CAPTCHAs, or anti-bot checks.

## 1. Confirm eligibility and permission compatibility

- [ ] Ask Apple about eligibility for an AI app with user-controlled general browsing, or submit an entitlement request describing Ox honestly.
- [x] Remove the native Bluetooth service, provider/helpers, session ownership, permission requests, usage key, and translations with maintainer approval.
- [x] Remove the read/write Photos provider, native actions, bundled service, permission key, and permission translations with maintainer approval.
- [x] Preserve and simulator-verify picker-based photo attachments without Photos library authorization. Add-only image saving is not implemented.
- [x] Audit declared capabilities and permission keys against Apple's published browser requirements; findings below do not establish Apple approval.
- [x] Remove Photos and Bluetooth authorization requests together with `apps/ios/Info.plist` declarations.

Gate: obtain maintainer agreement on feature trade-offs and clarify eligibility before undertaking a large redesign.

Audit findings:
- Both `NSPhotoLibraryUsageDescription` and `NSBluetoothAlwaysUsageDescription` are removed from the app.
- The removed `PhotoLibraryProvider.swift` requested `.readWrite` authorization for library search and album operations. Limited-library authorization was not a compliance workaround and cannot create or fetch user albums.
- Conversation attachments already use SwiftUI's system Photos picker. Preserve this path. Add-only access is not a replacement for searching existing assets or organizing existing albums.
- The removed Bluetooth provider supported foreground-only scanning and BLE/GATT interactions. System-managed Bluetooth accessories are not disabled.
- The published service-manifest Bluetooth permission token remains accepted but always denied without prompting; the manifest schema is unchanged.
- Apple's modern CoreBluetooth key requirement conflicts with its browser guidance. Any future reintroduction of native Bluetooth requires Apple clarification, not an unverified usage-key substitution.
- No always-on location, HomeKit, or Health usage keys are declared. Location access is while-in-use. Contacts, calendar, reminders, camera, microphone, local-network access, background processing, and iCloud capabilities are not explicitly forbidden by this browser guide, but that is not approval for their use in Ox.
- No associated-domain entitlement claims are present. Adding the browser entitlement would prevent Ox from claiming Universal Links for specific domains, so account for that in future authentication and linking decisions.
- HTTP/HTTPS scheme declarations are implemented; the browser entitlement remains absent. Launch-time browser accessibility and physical-device external-link behavior still require later UX/navigation audits.

Questions to submit to Apple after maintainer review:
1. Can Ox qualify for `com.apple.developer.web-browser` as an AI assistant with a user-controlled general WebKit browser, if it meets launch-time browsing and external HTTP/HTTPS navigation requirements?
2. Ox has removed native CoreBluetooth functionality. If foreground-only BLE support is reconsidered later, what supported configuration would satisfy both the browser prohibition and the modern Bluetooth usage-key requirement?
3. Ox has removed PhotoKit `.readWrite` features and retained system-picker attachments. Are there additional Photos restrictions beyond avoiding library access and using add-only authorization for any future saving?
4. Are there additional restrictions on Ox's user-authorized Contacts, calendar, reminders, camera, microphone, local-network, background-processing, or iCloud features?
5. What build and review evidence should accompany the request, and how can external-link behavior be demonstrated before production entitlement approval?

No inquiry has been submitted. Photos and Bluetooth removals are approved and implemented. Do not represent the remaining compliance plan as implemented or Apple-approved.

Apple's public guidance does not specify whether entitlement assessment uses the published version or the latest uploaded build; the request form requires sign-in and its evidence fields have not been inspected. Identify the intended candidate version/build and any available TestFlight access, distinguish it from the published version, and ask Apple which build to assess. Do not assume the latest upload is automatically assessed or that the changes must be published first. Managed-capability approval does not replace App Review of the submitted entitled build.

## 2. Complete the minimum browser experience

Build on `apps/ios/Client/UI/WebBrowserView.swift`, `ServiceBrowserView`, and `LinkOpener`. Keep the conversation as the launch screen; add no top-bar chrome. Every entry path reuses `LinkOpener`/`AppPresentationCoordinator.presentBrowser` and creates no conversation.

Existing: `.browse` mode already has editable address entry, back/forward, reload/stop, progress, a "Try Again" error overlay, Share, and Open in Safari.

Entry points (approved direction: composer URL, "+" menu, empty start page with service websites; recent pages deferred):
- [x] Reproduce current state on a simulator: no launch path reaches the Browser without the agent or an external link.
- [x] Composer URL: when trimmed composer text is a single bare domain or `http(s)` URL, show an "Open <host>" suggestion using the existing composer suggestion-panel pattern. Selecting it opens the Browser and keeps the draft; Send still goes to the agent. Ignore multi-word text and `sandbox:` links.
- [x] "+" menu: add a "Browser" row to `AttachMenuCard` that opens an empty Browser with the address field focused.
- [x] Empty Browser: let `ServiceBrowserSession` start without an initial URL, auto-focus the address field, and show a start page instead of a blank web view.
- [x] Start page: list web services (saved first) by name, favicon, and manifest `baseUrl`; tapping one navigates the same session. Saved services and website data are still app-wide, not Profile-owned. No new persisted state.
- [x] Show a neutral empty state when no web services exist; address entry stays primary. Not simulator-verified because bundled services are always present.
- [ ] Address submission: bare domains resolve to `https://`; non-URL text is rejected with an alert. Decide whether non-URL text is rejected or sent to a web search before shipping (search provider choice must stay neutral).

Navigation audit:
- [ ] Verify back/forward/reload/stop and "Try Again" stay reachable with collapsed chrome, a first-load failure, and an empty session.
- [ ] Show the current domain (already shown) and the owning Profile name once Profile isolation lands; until then do not imply Profile-owned sessions.
- [ ] Keep popups, downloads, tabs, and history out of this step; they are tracked in section 4 or deferred.

Recent pages (deferred, needs approval): Profile-local capped list of URL, title, and last visit, recorded only for user-initiated top-level navigations, cleared with Profile website data, logged by domain only. It is a new persisted file, so it requires predecessor/changed-build evidence and should follow Profile isolation.

Verification:
- [ ] Simulator E2E on iPhone and iPad layouts with VoiceOver labels and stable identifiers for each new control and per-service row. iPhone (ox-1, iOS 26) verified: "+" → start page, address entry, tile navigation, composer suggestion (`hello`/`hello world` show none; `Apple.com/iphone` opens www.apple.com), draft retained. iPad and dark mode pending.
- [ ] Screenshots of composer suggestion, "+" menu row, empty start page, and no-services state for review.
- [ ] Report LOC, cyclomatic complexity, file-tree, and call-stack diffs.

Gate: a reviewer can open Ox, reach a website in one or two taps without the agent, and recover from navigation errors.

## 3. Handle links opened by other apps

- [x] Declare `http` and `https` URL schemes in `apps/ios/Info.plist`.
- [x] Route web URLs before document imports into the existing Browser, without creating an agent conversation or falling back to external opening.
- [x] Use the selected Profile; retain the latest incoming link until onboarding, foreground activity, Profile preparation, and conflicting presentations allow opening. Offer retry or cancellation if preparation fails.
- [x] Verify targeted simulator delivery for cold launch with delayed preparation, warm launch, and an existing Browser.
- [x] Verify HTTP paths, query strings, fragments, redirects, and a `.chat` website path without importing it.
- [x] Verify onboarding deferral and latest-link retention on a simulator.
- [x] Defer links until Settings/Services sheets finish dismissal and Profile operations finish; verify Settings deferral, latest-link retention, and delivery after a Profile switch.
- [x] Verify preparation failure, retry under continued failure, cancellation, and successful delivery after normal relaunch using a Debug Simulator template-input failure.
- [ ] Verify all conflicting presentation types, multiwindow ownership, and physical-device default-browser delivery. The app declares multiple-scene support, but presentation ownership is still shared.
- [ ] Establish Profile website isolation; switching currently retains the app-wide website session.

Gate: demonstrate that external links open correctly, not merely that Browser can open URLs internally.

## 4. Audit navigation and website compatibility

Review `apps/shared/Host/Services/Web/ServiceWebKit.swift` and its navigation collaborators.

- [x] Confirm ordinary `ServiceBrowserSession` browsing supports HTTP independently of the restricted agent-controlled browser policy; keep that policy intact.
- [x] Enable HTTP only for WebKit content using `NSAllowsArbitraryLoadsInWebContent`; keep URLSession ATS unchanged. Verify a local HTTP page and redirect.
- [x] Simulator-verify a redirect, POST form submission, JavaScript location navigation, and a same-document history route on a controlled HTTP fixture.
- [x] Verify `target="_blank"` links open their destination in the same Browser page.
- [ ] Handle JavaScript popups coherently. A user-triggered `window.open(url, "_blank")` did not navigate in the current WebPage browser; flows requiring a separate window/opener are unverified.
- [x] Explicitly reject download requests, attachment responses, and unsupported content with the shared chat-style Liquid Glass error toast below the Browser toolbar while retaining the current page; verify attachment and unsupported-content responses on a simulator.
- [ ] Implement actual download saving; rejection is not download support.
- [x] Report unavailable external apps instead of silently discarding the link; simulator-verify an unregistered app scheme.
- [ ] Verify successful external-app handoff on a physical device.
- [x] Preserve controlled fixture destinations, form method, and page content without creating agent workflows.
- [x] Keep the restricted agent-browser policy and URLSession ATS unchanged; ordinary manual browsing remains independently HTTP/HTTPS-capable.

## 5. Establish Profile isolation

- [ ] Use the intended Profile's WebKit website-data store for browsing, manual login, and subsequent service actions.
- [ ] Verify cookies, local storage, and cached website data do not leak across Profiles.
- [ ] Provide clear website-data deletion behavior.
- [ ] Distinguish Profile-local website sessions from system-managed passkeys; passkeys are not Ox Profile secrets.
- [ ] Avoid persisted-storage changes unless needed. If needed, use scoped migration owners and obtain actual predecessor/changed-build compatibility evidence before release.

Audit: `ServiceWebsiteDataCoordinator.dataStoreID` hashes only the app's website-data namespace. Manual browsing, sign-in/handoff, and service actions use that same app-wide store. A cookie and local-storage marker written in Default were visible after switching to a newly created QA Profile; that Profile and the markers were removed afterward. Cache isolation is not established either. Existing service website-data deletion clears the shared site's data, not one Profile's data; arbitrary Browser-site deletion and active-page quiescence remain unfinished. System passkeys must not be described as Profile-owned secrets.

Gate: agree which Profile, if any, inherits existing shared website sessions before implementing the storage transition. Do not copy authenticated sessions into every Profile. Preserve older data until scoped migration and actual predecessor/changed-build evidence establish the intended behavior; report downgrade incompatibilities before release.

## 6. Configure approved signing

After Apple grants approval:

- [ ] Enable the approved capability for Ox's App ID.
- [ ] Add `com.apple.developer.web-browser` to `apps/ios/ios.entitlements`.
- [ ] Refresh development and distribution provisioning profiles.
- [ ] Verify the entitlement in the signed app.
- [ ] Verify Ox appears as an available default-browser choice.

Adding an entitlement locally without approval and matching provisioning is insufficient.

## 7. Verify built-in passkey handling

- [ ] Start with websites' normal WebAuthn requests and WebKit's built-in handling.
- [ ] Determine whether browser credential-manager authorization APIs are needed for the selected flow; do not assume custom credential enumeration is required.
- [ ] Verify passkey registration and sign-in on a controlled test site and real third-party websites.
- [ ] Verify system Passwords and supported third-party credential providers.
- [ ] Verify cancellation, denied access, no matching credential, and supported cross-device authentication.
- [ ] Verify passkeys with Ox selected and not selected as the default browser.
- [ ] Keep credential material and sensitive authentication responses out of diagnostics.

Gate: reproduce the current failure and demonstrate the same flow succeeding in an entitled physical-device build before claiming the restriction is resolved.

Apple documents automatic WebAuthn handling in WebKit browser apps. Its separate `com.apple.developer.web-browser.public-key-credential` entitlement explicitly allows passkey registration and assertion for "any relying party identifier", but is documented for macOS and Mac Catalyst, not iOS/iPadOS. Do not add that desktop entitlement to the iPhone app or treat its wording alone as proof of the iOS configuration. WebKit's iOS test-runner change adding `com.apple.developer.web-browser`, with reported WebAuthn availability-test results, corroborates the iOS entitlement's relevance but does not establish successful passkey ceremonies in Ox.

The retrieved sources support the browser route for third-party domains without individual website associations, but do not explicitly establish the entire iOS entitlement-to-associated-domain-exemption chain or passkey behavior when Ox is not selected as default. Ask Apple to confirm both. Verify registration and sign-in on unrelated domains absent from Ox's associated domains, with Ox selected and not selected as default. Normal origin/relying-party protections, user consent, website policies, and compatibility limitations remain; browser-wide support is not a guarantee that every website works.

## 8. Prepare verification and Apple review

- [ ] Run E2E verification on physical iPhone and supported iPad layouts, including accessibility.
- [ ] Exercise external links, redirects, popups, uploads, downloads, and Profile switching.
- [ ] Capture screenshots or video for human visual review; keep evidence outside the repository.
- [ ] Keep sanitized structured logs sufficient to diagnose production failures.
- [ ] Prepare concise review instructions demonstrating general browsing and external-link handling.
- [ ] Review LOC, cyclomatic complexity, file-tree changes, and call-stack changes for each implementation change.

Execution order: eligibility and permission clarification → minimum browser UX → external-link handling → navigation and Profile verification → approved signing → physical-device passkey verification.

## Evidence and references

Sections 3–5 audit: iOS 26 simulator ox-2, baseline and changed Debug builds succeeded. Controlled HTTP fixture requests, native input, AX alerts, and screenshots verified the paths marked above. Evidence is outside Git at `/tmp/ox-browser-audit/`; no real website authentication, entitled physical-device delivery, or passkeys were tested. Profile isolation and JavaScript popup checks failed as described above; rejection notices do not establish download support.

Apple requirements and APIs:
- [Preparing your app to be the default browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)
- [Default-browser entitlement request](https://developer.apple.com/contact/request/default-browser-entitlement/)
- [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)
- [Browser credential manager](https://developer.apple.com/documentation/authenticationservices/asauthorizationwebbrowserpublickeycredentialmanager)
- [macOS/Mac Catalyst browser passkey entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential): explicitly permits requests for any relying party identifier; not an iOS entitlement.
- [WebKit iOS test-runner entitlement change](https://github.com/WebKit/WebKit/pull/22913): implementation corroboration, not Ox passkey verification.
- [WebKit App-Bound Domains](https://webkit.org/blog/10882/app-bound-domains/): describes all-domain API access for entitled browsers, not a passkey-specific guarantee. App-bound domains and associated domains are distinct mechanisms.
- [Bluetooth usage-key requirement](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)
- [Older Bluetooth usage-key guidance](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothperipheralusagedescription)

Developer reports support attainable approval but not predictable turnaround:
- [Crest developer](https://www.reddit.com/r/browsers/comments/1vjef6c/crest_browser_inspired_by_arc_testflight_open/) reports mobile approval and working passkeys; this is self-reported, not independently tested in Ox.
- [External-link rejection](https://www.reddit.com/r/swift/comments/lfszlj/help_default_browser_entitlement_request/) identifies incorrect URL-opening handling, with no eventual approval confirmed in the retrieved comments.
- [2020 waiting report](https://developer.apple.com/forums/thread/660585), [review/change requests](https://developer.apple.com/forums/thread/700605), and [2023 three-month wait](https://developer.apple.com/forums/thread/730459) were available through search-indexed excerpts; direct retrieval encountered security verification. Historical anecdotes are not a current approval SLA.

Do not conflate the default-browser entitlement with EU alternative-browser-engine entitlements. This plan retains Apple's system WebKit.
