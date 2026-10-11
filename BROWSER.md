# Ox browser plan

Goal: qualify Ox as an Apple-approved browser so users can authenticate to third-party websites with passkeys inside Ox. Keep the existing WebKit browser and Profile-owned website sessions; do not build a separate engine or custom JavaScript passkey bridge.

Status: external-link handling is implemented and simulator-verified; the remaining compliance work is proposed. Apple approval and passkey behavior in an entitled Ox build remain unverified. Users should not need to select Ox as their default browser to use embedded passkeys; verify this on-device before promising support.

## Benefits and trade-offs

Benefits:
- Passkeys for third-party websites without requiring each website to authorize Ox through associated domains.
- Authentication stays inside Ox's browser and its appropriate Profile website-data store.
- System-managed credential selection and user verification; Ox does not store passkey private keys.
- Eligibility as a default-browser option and additional documented browser capabilities, including Service Workers.

Costs and limitations:
- Apple-managed entitlement approval has uncertain eligibility and timing.
- Native photo-library search and album organization are removed; user-selected photo attachments remain available.
- Current Bluetooth permission key conflicts with the published requirements; retaining foreground CoreBluetooth functionality needs Apple clarification.
- General browsing, external-link handling, and broader compatibility testing become ongoing responsibilities.
- Passkeys still require user participation and do not resolve embedded OAuth rejection, CAPTCHAs, or anti-bot checks.

## 1. Confirm eligibility and permission compatibility

- [ ] Ask Apple about eligibility for an AI app with user-controlled general browsing, or submit an entitlement request describing Ox honestly.
- [ ] Clarify whether foreground CoreBluetooth functionality can coexist with the browser entitlement.
- [x] Remove the read/write Photos provider, native actions, bundled service, permission key, and permission translations with maintainer approval.
- [x] Preserve and simulator-verify picker-based photo attachments without Photos library authorization. Add-only image saving is not implemented.
- [x] Audit declared capabilities and permission keys against Apple's published browser requirements; findings below do not establish Apple approval.
- [x] Remove Photos authorization requests together with `apps/ios/Info.plist` declarations; keep Bluetooth unchanged pending clarification.

Gate: obtain maintainer agreement on feature trade-offs and clarify eligibility before undertaking a large redesign.

Audit findings:
- `NSPhotoLibraryUsageDescription` is removed from the built app; the explicitly prohibited `NSBluetoothAlwaysUsageDescription` remains unresolved.
- The removed `PhotoLibraryProvider.swift` requested `.readWrite` authorization for library search and album operations. Limited-library authorization was not a compliance workaround and cannot create or fetch user albums.
- Chat attachments already use SwiftUI's system Photos picker. Preserve this path. Add-only access is not a replacement for searching existing assets or organizing existing albums.
- `BluetoothProvider.swift` rejects operations unless the app is active and closes its session when backgrounded. `UIBackgroundModes` declares processing, not Bluetooth modes. Nevertheless, the prohibited key remains present.
- Apple's current Bluetooth-key documentation says `NSBluetoothAlwaysUsageDescription` is required when using the device's Bluetooth interface. Its browser guide instead recommends `NSBluetoothWhileInUseUsageDescription`. Treat this documentation conflict as unresolved; do not substitute keys without a supported solution from Apple.
- No always-on location, HomeKit, or Health usage keys are declared. Location access is while-in-use. Contacts, calendar, reminders, camera, microphone, local-network access, background processing, and iCloud capabilities are not explicitly forbidden by this browser guide, but that is not approval for their use in Ox.
- No associated-domain entitlement claims are present. Adding the browser entitlement would prevent Ox from claiming Universal Links for specific domains, so account for that in future authentication and linking decisions.
- HTTP/HTTPS scheme declarations are implemented; the browser entitlement remains absent. Launch-time browser accessibility and physical-device external-link behavior still require later UX/navigation audits.

Questions to submit to Apple after maintainer review:
1. Can Ox qualify for `com.apple.developer.web-browser` as an AI assistant with a user-controlled general WebKit browser, if it meets launch-time browsing and external HTTP/HTTPS navigation requirements?
2. Can Ox retain foreground-only CoreBluetooth operations? The app closes Bluetooth sessions on backgrounding and does not declare Bluetooth background modes. How should it satisfy both the browser prohibition and the modern Bluetooth usage-key requirement?
3. Ox has removed PhotoKit `.readWrite` features and retained system-picker attachments. Are there additional Photos restrictions beyond avoiding library access and using add-only authorization for any future saving?
4. Are there additional restrictions on Ox's user-authorized Contacts, calendar, reminders, camera, microphone, local-network, background-processing, or iCloud features?
5. What build and review evidence should accompany the request, and how can external-link behavior be demonstrated before production entitlement approval?

No inquiry has been submitted. Photos removal is approved and implemented; Bluetooth feature removal still requires maintainer approval. Do not represent the remaining compliance plan as implemented or Apple-approved.

## 2. Complete the minimum browser experience

Build on `apps/ios/Ox/Client/UI/WebBrowserView.swift`.

- [ ] Provide readily accessible URL entry, web search, or curated bookmarks from launch; Apple's criteria permit these alternatives.
- [ ] Allow browsing without asking the agent first.
- [ ] Clearly show the current website/domain and the Profile owning its session.
- [ ] Provide back, forward, reload/stop, and navigation-error recovery.
- [ ] Preserve ordinary website content and user navigation while keeping agent assistance available.
- [ ] Assess existing behavior before adding UI; tabs, bookmarks, and history are product choices, not all explicit entitlement prerequisites.

## 3. Handle links opened by other apps

- [x] Declare `http` and `https` URL schemes in `apps/ios/Info.plist`.
- [x] Route web URLs before document imports into the existing Browser, without creating an agent chat or falling back to external opening.
- [x] Use the selected Profile; retain the latest incoming link until onboarding, foreground activity, Profile preparation, and conflicting presentations allow opening. Offer retry or cancellation if preparation fails.
- [x] Verify targeted simulator delivery for cold launch with delayed preparation, warm launch, and an existing Browser.
- [x] Verify HTTP paths, query strings, fragments, redirects, and a `.chat` website path without importing it.
- [ ] Verify onboarding, conflicting presentations, preparation failures, Profile switching/isolation, multiple windows, and physical-device default-browser delivery.

Gate: demonstrate that external links open correctly, not merely that Browser can open URLs internally.

## 4. Audit navigation and website compatibility

Review `apps/ios/Ox/Host/Services/Web/ServiceWebKit.swift` and its navigation collaborators.

- [x] Confirm ordinary `ServiceBrowserSession` browsing supports HTTP independently of the restricted agent-controlled browser policy; keep that policy intact.
- [x] Enable HTTP only for WebKit content using `NSAllowsArbitraryLoadsInWebContent`; keep URLSession ATS unchanged. Verify a local HTTP page and redirect.
- [ ] Verify redirects, forms, JavaScript navigation, and same-document routes.
- [ ] Handle popup and `target="_blank"` requests coherently.
- [ ] Handle downloads, unsupported content types, and external app schemes.
- [ ] Preserve expected website destinations and content rather than redirecting links into agent workflows.
- [ ] Keep network protections explicit; do not remove safeguards solely to broaden browsing.

## 5. Preserve Profile isolation

- [ ] Use the intended Profile's WebKit website-data store for browsing, manual login, and subsequent service actions.
- [ ] Verify cookies, local storage, and cached website data do not leak across Profiles.
- [ ] Provide clear website-data deletion behavior.
- [ ] Distinguish Profile-local website sessions from system-managed passkeys; passkeys are not Ox Profile secrets.
- [ ] Avoid persisted-storage changes unless needed. If needed, use scoped migration owners and obtain actual predecessor/changed-build compatibility evidence before release.

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

## 8. Prepare verification and Apple review

- [ ] Run E2E verification on physical iPhone and supported iPad layouts, including accessibility.
- [ ] Exercise external links, redirects, popups, uploads, downloads, and Profile switching.
- [ ] Capture screenshots or video for human visual review; keep evidence outside the repository.
- [ ] Keep sanitized structured logs sufficient to diagnose production failures.
- [ ] Prepare concise review instructions demonstrating general browsing and external-link handling.
- [ ] Review LOC, cyclomatic complexity, file-tree changes, and call-stack changes for each implementation change.

Execution order: eligibility and permission clarification → minimum browser UX → external-link handling → navigation and Profile verification → approved signing → physical-device passkey verification.

## Evidence and references

Apple requirements and APIs:
- [Preparing your app to be the default browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)
- [Default-browser entitlement request](https://developer.apple.com/contact/request/default-browser-entitlement/)
- [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)
- [Browser credential manager](https://developer.apple.com/documentation/authenticationservices/asauthorizationwebbrowserpublickeycredentialmanager)
- [Bluetooth usage-key requirement](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)
- [Older Bluetooth usage-key guidance](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothperipheralusagedescription)

Developer reports support attainable approval but not predictable turnaround:
- [Crest developer](https://www.reddit.com/r/browsers/comments/1vjef6c/crest_browser_inspired_by_arc_testflight_open/) reports mobile approval and working passkeys; this is self-reported, not independently tested in Ox.
- [External-link rejection](https://www.reddit.com/r/swift/comments/lfszlj/help_default_browser_entitlement_request/) identifies incorrect URL-opening handling, with no eventual approval confirmed in the retrieved comments.
- [2020 waiting report](https://developer.apple.com/forums/thread/660585), [review/change requests](https://developer.apple.com/forums/thread/700605), and [2023 three-month wait](https://developer.apple.com/forums/thread/730459) were available through search-indexed excerpts; direct retrieval encountered security verification. Historical anecdotes are not a current approval SLA.

Do not conflate the default-browser entitlement with EU alternative-browser-engine entitlements. This plan retains Apple's system WebKit.
