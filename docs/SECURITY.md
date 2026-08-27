# Security

Ox's product *is* a security boundary. The agent acts on real websites with
the user's live credentials, with no API keys and no cooperation from the sites
themselves — so the value proposition and the threat model are the same thing.
This document records what Ox defends, who it defends against, and where the
sharp edges are. Persisted state belongs in
`.agents/skills/storage-migrations/references/storage.md`.

## Trust boundaries

Ox is three independent layers over one public-shape interface. The security
boundaries do not line up one-to-one with the layers — the important ones cut
*through* the Client:

- **The model** — untrusted. Model output is executable JavaScript, and it is
  assumed to be adversarial at all times. Every guarantee below must hold even
  when the model is actively trying to break it.
- **The agent virtual machine** — the isolated runtime the model's JavaScript executes
  in. Trusted to *compute*, never to *reach*: no direct network, timers, DOM,
  credential visibility, or raw filesystem. It can only request named actions;
  every execution receives a fresh JavaScript context and global environment.
  Executions may share a serialized JavaScript virtual machine, but native code
  does not pass JavaScript values between their contexts; continuation crosses
  executions only through model-visible output or an authorized virtual file.
  Artifact actions accept validated basenames scoped to the active Profile. The
  attached Web device service is the explicit exception that lets one
  approved named action execute model-supplied JavaScript in Web's page.
- **The Credential Firewall** — the single narrow seam between the virtual machine and
  the outside world. Intent crosses in (a named action + arguments); a
  schema-validated JSON result crosses back out. Bounded credential-free native
  helpers may retain an opaque HTTP body capability for explicit artifact read,
  transient model attachment, or approved artifact import. Raw response bytes
  never enter the JavaScript virtual machine.
- **Service pages** — a manager-owned pool of up to five `WebPage` instances,
  keyed by an action's effective base URL and backed by one persistent app-wide
  website data store. This is where credentials live and where a service's fetch
  logic runs, in the visited site's own page world alongside the site's own
  (untrusted) JavaScript.
- **Remote MCP servers** — user-configured network peers that supply untrusted
  tool metadata and receive approved, schema-validated arguments directly from
  the device. They receive no ambient website or provider credentials.
- **Service repositories** — the signed app bundle and user-enabled public git
  repositories that publish service definitions. A git host sees only git
  verbs; it never learns which actions ran or what data crossed the firewall.
  Repositories *supply the code* that runs inside service pages, which makes
  their integrity and conflict selection first-class concerns.

## Assets

1. **Site credentials** — the per-origin cookie jars. The crown jewels; a
   person signs in once and the session is the standing credential.
2. **User data** — chat history, on-device memory, and the sensitive device
   surfaces the agent can touch (artifacts, user-selected Files folders, contacts,
   location, calendar, messages, and Apple Health summaries).
3. **Action integrity** — the guarantee that state-changing operations (money,
   posting, sending) happen only with the user's approval.
4. **Infrastructure secrets** — the LLM provider keys.

## Threats and mitigations

### T1 — Adversarial model exfiltrates credentials
The model tries to read a cookie, token, or key and send it somewhere.
**Mitigation:** outside the Web device service, the virtual machine has
zero credential visibility and zero network by construction. Credentials never
enter the virtual machine; they live only in the service pages on the far side
of the firewall. The model can request a named action but never holds the
material an action uses. Service results come back as
schema-validated JSON, while named public-web helpers use isolated ephemeral
requests with no cookies, cache, stored credentials, or ambient authorization.
App inspection reports provider authentication method and readiness as bounded
enums; it never serializes credential values, account labels, profile identifiers,
or internal filesystem paths into the virtual machine.
Fetched bodies are bounded and held only for the active JavaScript execution.
The virtual machine must explicitly read a body, add it to model context, or request an
approval-gated artifact import; fetching alone does neither. URL provenance and
DNS rebinding protection remain deferred and must be addressed before the public
web contract expands. **Web exception:** after approval, the model may
read page-visible credentials and authenticated data and use Web's current
page to transmit them. Always approve makes that exception standing across every
page Web visits until the user revokes the qualified
`device.browser:executeJavaScript` approval.

### T2 — Adversarial model triggers a harmful state change
The model invokes a money-moving, posting, or sending action the user didn't
intend. **Mitigation:** service definitions must mark state-changing actions
`requireApproval`, and the native runtime enforces that policy independent of
how the model names or chains the call. The default is a per-invocation prompt;
the user may deliberately persist “Always approve” for one qualified action, which
turns that decision into standing consent until revoked. Importing a public
resource and renaming or deleting an artifact are approval-gated. Writing or
editing Profile-owned artifact content is treated like generating chat content and
does not prompt; Files-folder mutations use the separate device-service policy
described below. Authenticated actions re-probe auth at invoke time rather than
trusting a cached signal. Payment completion stays on the merchant's
user-operated review surface rather than becoming an agent action.

Web cannot preserve per-operation mutation policy: one script may
invoke page APIs, dispatch UI events, call installed service handlers, or
schedule later work. Its action approval therefore authorizes all website reads
and mutations performed by that script. Persisting Always approve is standing
consent to that control across pages Web visits, not merely consent to one
kind of website mutation.

Settings offers an explicit, off-by-default **Always approve** switch for
all chats and Profiles on the device. Settings and the enable confirmation warn
about data loss and unwanted charges. Enabling it requires confirmation and
approves both pending and future ordinary action prompts, including service
attachment and Browser control. It persists across launches until disabled.
Per-action standing approvals remain separate and take effect again when the
global switch is off. Auto-approved actions and changes to the switch are logged.
This does not bypass authentication, iOS permissions, selected-folder boundaries,
private-data storage and disclosure consent, or ordinary questions to the user.

Device capabilities follow the same attachment boundary as registry services but
execute locally. A device service must be attached to the chat before its actions
are disclosed or callable; the applicable iOS permission remains an independent
OS-controlled gate. Files adds a third boundary: the folders chosen in the system
picker are the Files service's scope. Once that service is attached, `ox.fs`
can operate only inside those virtual mounts. Write, edit, and delete additionally
require per-action approval unless the user explicitly allows that action without
asking. Profile-owned memory, soul, artifact, and skill paths are not part of the
Files service scope. Security-scoped bookmarks expose neither an unrestricted
Files root nor an ambient iCloud Documents directory.

Opening a Profile is a separate user-directed folder selection. Its
bookmark authorizes Ox's repository to use that one vault in place until the
user closes the Profile. It does not attach the folder to a chat or expose the
parent directory through `ox.fs`.

Persisted chats in the active Profile are part of that Profile's agent-visible data scope.
The virtual filesystem exposes their stored `chat.json` metadata and
`turns.jsonl` transcripts read-only, without host paths or the runtime
`context.json` checkpoint. Root grep deliberately excludes chat history; the
model must search `chats/` or one of its descendants explicitly. This limits
accidental bulk retrieval, not an adversarial model: once a transcript is read,
its contents may be disclosed to the selected model provider and composed with
later actions just like memory or artifacts. Users should therefore treat a Profile
as the privacy boundary between chat collections and choose its model provider
accordingly.

Remote MCP tools also follow the attachment boundary. Discovered metadata is
treated as untrusted, duplicate or malformed tool contracts are rejected,
responses are capped at 4 MiB, redirects are refused, and every tool is
approval-gated by default. Production accepts only public HTTPS endpoints.
OAuth discovery, dynamic client registration, authorization-code exchange with
S256 PKCE, refresh, and bearer-token use happen directly between the device and
the remote authorization or MCP server. The browser callback uses a localhost
listener; Ox's API and registry never receive the authorization code, client
registration, token, tool arguments, or tool results. Registration and tokens
are stored as one Keychain credential scoped to the endpoint and removed on
disconnect. Approved arguments and returned data are disclosed to the selected
MCP server by design. Hostname DNS rebinding protection remains deferred
alongside the public-web limitation described above. Server-declared icons are
untrusted: Ox accepts only bounded PNG or JPEG data, refuses redirects, and
loads network icons only from the MCP endpoint's registrable domain.
Web service icons follow the same bounded image and no-redirect rules. The
built-in manifests point to `openox.ai` CloudFront URLs backed by a private S3
bucket, and icon requests use an ephemeral session without cookies or stored
credentials.

Location requests default to iOS reduced accuracy, and coordinates returned to
the agent are additionally quantized. Nearby place search and route calculation
may use the device's native fix inside the iOS process, but the precise origin
does not cross into the agent virtual machine. Search results are bounded and distances
are rounded before crossing the bridge. Opening a selected result hands its
stable MapKit place identifier to the user-visible Apple Maps app.

### HealthKit boundary

Apple Health access is read-only and limited to five bounded domains: daily
activity aggregates; daily sleep duration and stages; workout summaries without
routes; daily resting heart rate, heart-rate variability, and respiratory-rate
averages; and daily weight and body-composition trends. Every query spans at most
31 days, and workout output is capped at 200 records.

Ox applies two app-controlled gates before asking HealthKit for data. A
persisted chat in an iCloud Profile must first restart as a memory-only temporary
chat or in a Profile stored on the device. Then every read displays the exact data
category, date range, bounded agent-supplied purpose, and current inference
destination. A remote model requires one-time “Share Once” approval naming the
provider; an on-device model requires one-time read approval and makes no remote
disclosure claim. Standing approval is not offered. If the provider changes
while the prompt is open, Ox asks again for the new destination. Only after
approval does Ox request or reuse the per-type HealthKit permission managed by
iOS and execute the query.

The storage and disclosure policy is implemented by a source-neutral private-data
gate. The Health adapter supplies labels, validates the bounded request, and
performs the read; chat orchestration does not branch on HealthKit. Health values
are not included in diagnostic logs, and a missing value is never represented as
an authorization decision because HealthKit intentionally makes denied read
access look like no matching data.

**Residual risk:** approved results enter the selected model's context and are
then subject to that provider's data handling. The agent may compose them with
later native, service, public-web, memory, skill, or artifact actions under those
actions' normal policy. Temporary chats prevent Ox persistence and iCloud sync,
not provider processing. HealthKit permission covers Ox's native read, not every
possible downstream use of the resulting summary.

### T3 — Malicious or compromised service definition (highest residual risk)
A hostile repository ships fetch logic that runs inside a service page in
the user's authenticated origin — the most powerful position in the system,
because there it legitimately holds that origin's cookies. **Mitigation:** the
same-origin policy confines DOM and origin-storage access, while actions are
disabled whenever the page leaves the service's declared domain;
git history makes published remote states auditable and recoverable; conflicts
are resolved as whole services instead of merging code across repositories; and
mutating actions remain approval-gated. A chat records a hash of the selected
repository revisions it last loaded, but the current client executes the active
working trees; reproducible per-chat execution pinning is not yet a mitigation.
**Residual risk:** within its own origin a malicious action is
inherently potent. The long-term backstop is the Network layer — the consensus
mesh that evaluates service forks before fast-forward-merging them — which is
still emerging. Until pinning and that network mature, registry trust is the
softest part of the model, and service definitions should be reviewed like the
credentialed code they are.

### T4 — Cross-origin / cross-service leakage
One service reads another's session, or an off-domain page is treated as a
service. **Mitigation:** each service owns its pages, WebKit's same-origin
policy separates origin storage, actions remain unavailable while a page is
off the service's own domain, and bridge messages are validated against the
frame's security origin before being trusted. Signing out removes only WebKit
records and cookies mapped to the service's Public Suffix List-aware
registrable domain. **Residual risk:** all pages share one browser profile.
Cross-origin navigation and requests can therefore carry ambient
credentials for unrelated sites under normal browser cookie and CORS rules,
even though service code cannot directly read another origin's storage.

### T5 — A visited site's own JavaScript attacks the client
Untrusted page JavaScript shares the page world with injected action logic and
tries to reach a privileged native channel. **Mitigation:** the only channels
exposed to the page world are logging-only and return nothing to the page; the
privileged action-invocation path is not reachable from page script, and
message origins are validated.

### Web device-service boundary

`device.browser` is a client-owned device service with `navigate`, `inspect`, and
`executeJavaScript` actions and one persistent primary page. `navigate` accepts
only an absolute HTTP or HTTPS URL allowed by the web-navigation policy.
`inspect` only materializes a persistent chat row; it does not execute page code
or present UI. Web's live page appears in the existing inspector only after
the user taps that row. `executeJavaScript` accepts a non-empty bounded script,
obtains the ordinary native action approval, serializes execution against page
navigation, and runs the script as an async function body in the page content
world. No domain selector is exposed, and only a JSON-compatible result crosses
back to the agent. Web uses the shared website data store, so visiting an
origin can use the same signed-in session as that origin's registry service.

The approval UI intentionally offers Always approve and stores it under the
qualified `device.browser:executeJavaScript` action name. While enabled, the model
can inspect or mutate the current DOM, origin storage, page JavaScript state, and
authenticated responses; initiate network requests; and leave timers, listeners,
storage changes, or other origin-scoped state behind. Navigation changes the
origin controlled by later invocations but does not undo work already initiated
by a script. This mode explicitly suspends credential confidentiality and
per-mutation integrity for Web's current origin. Provider keys, native device
capabilities, raw files, and Ox bridges remain outside Web's page.

### Interactive authentication boundary

The `getSignInUrl` and `getSignInState` actions acquire service pages from the same
effective-URL pool as other actions. Interactive sign-in opens the URL returned
by `getSignInUrl` in a dedicated visible handoff page backed by the same website
data store. The handoff page never receives the service action bundle, console
bridge, or network bridge. Native message handlers on pooled service pages remain
origin-gated and reject messages from other domains.

The main frame may follow public HTTPS navigation chosen by the user; simulator
fixtures additionally permit explicit loopback HTTP. Private-network
destinations, local files, data URLs, JavaScript URLs, and unexpected custom
schemes are rejected. There is no manifest domain allowlist for interactive
browsing. The visible destination hostname and the website content are the
user's trust decision, with the same phishing and malicious-redirect risks as
other embedded browsers.

A return to the service origin is only a completion candidate:
`getSignInState == signedIn` is the authoritative predicate. Action execution
remains unavailable off the service domain. Verification runs `getSignInState` on
a pooled service page after the handoff updates the shared website data.

This is an embedded-browser flow, not `ASWebAuthenticationSession`. It does not
share Safari login state, and providers that prohibit embedded user agents may
reject it. That compatibility limit must not be bypassed by disguising the user
agent or injecting privileged capabilities into off-service documents.

Popup requests remain in the same handoff page. Diagnostics record attempt
IDs, state transitions, destination hosts, navigation decisions, and probe
outcomes, but never cookies, authorization headers, form values, callback
queries or fragments, authorization codes, page contents, or complete URLs.

### Simulator bootstrap boundary

Website-data bootstrap is a DEBUG simulator facility for trusted local
operators, not part of the shipped credential firewall. An explicit source
simulator serializes the global profile's cookies and local storage into an
opaque credential-bearing blob. The host bootstrap process relays that blob
directly between loopback debug WebSockets and discards it after the target
restore. Profiles store only whether to copy website data; blobs and cookie values never enter
arguments, logs, artifacts, the agent virtual machine, or version control.

Any local process able to reach a simulator's debug port is already inside this
development trust boundary and can request an export. Numbered simulator and
port isolation, an explicit distinct source, bounded payloads, and DEBUG-only
command compilation constrain accidental exposure but do not defend against a
malicious process running as the same macOS user. IndexedDB is not copied because
WebKit 26.0 and 26.2 reject it for this serialization API, and the target copy is
a replacement rather than a merge or continuous synchronization mechanism.

### T6 — Repository transport tampering / MITM
An attacker intercepts a repository update to inject malicious service code.
**Mitigation:** the default repository is inside the code-signed app. Additional
repositories must be public HTTPS git URLs without embedded credentials, so TLS
authenticates the selected host and Ox ships no reusable repository secret.
Updates clone into staging, validate `repository.json`, manifest identity, file sizes,
paths, and symbolic links, reject external native iOS services, and replace the
active snapshot only after validation. A maliciously configured repository
remains trusted input rather than a transport attack.

### T7 — Infrastructure secret disclosure
**LLM keys:** held in the Keychain, attached only to the
correct provider host, and never logged or exposed to the virtual machine. They use
After First Unlock accessibility so user-invoked background Siri and CarPlay
requests can run while the phone is locked, but remain unavailable until the
first unlock after each restart.

**User-hosted LLM endpoints:** custom provider URLs and model capabilities are
local configuration; optional bearer tokens remain in the LLM Keychain. Ox
normalizes only HTTP(S) base URLs, never accepts arbitrary request headers, and
attaches a saved bearer only to the configured endpoint. Local HTTP traffic is
not encrypted, so the setup UI identifies it as local-network use and iOS asks
for Local Network permission before connecting. Private-data disclosure treats
user-hosted inference as off-device and names the configured provider.

### T8 — Local debug surface
A debug channel exposes evaluation and inspection over loopback. **Mitigation:**
it is compiled only into simulator builds and never ships to devices, and it
binds to loopback only. **Residual risk:** it performs no origin check on
connections, so a malicious page visited on the same developer machine could
reach it. This affects developers only, never shipped users; treated as a
developer-machine hardening note, not a shipped vulnerability.

### T9 — Artifact path escape or destructive file mutation
The model supplies a filename intended to escape the active Profile, overwrite an
unrelated file, or destroy user content. **Mitigation:** artifact actions accept
one normalized basename, reject separators and control characters, resolve it
only beneath the immutable active-Profile scope, bound reads and writes, and never
expose local URLs. Import, rename, and delete use the native approval policy.
Writes and edits within the active Profile do not prompt; they are confined to the
artifact, memory, soul, and user-skill namespaces and cannot reach chats,
manifests, host paths, app-owned `system:` skills, attached `service:` skills, or
unrelated vault contents. The virtual skill mount derives mutability from the
resolved source rather than skill frontmatter. Registry manifests are readable
through `services/`, but that mount is read-only and exposes neither service
source code nor website state. Files-folder writes, edits, and deletes
require the attached Files device service and its per-action approval. Artifact
contents are untrusted data and cannot override the current request or approval
policy. **Residual risk:** an adversarial model can overwrite an existing
Profile-owned artifact without a separate confirmation, matching the product
decision that artifact content generation is part of the requested response.

### T10 — Active content in an HTML artifact
An HTML canvas is executable code with Host service authority. Every presentation
uses a non-persistent WebKit data store and receives only the catalogued
`ox.service` SDK, excluding chat attachment lifecycle methods. Calls use the same
service implementations, authentication, sensitive-action approvals, and saved
approval settings as chat. There is no canvas-specific service allowlist or grant
store. Actions without an approval requirement may execute silently, including
signed-in reads; the action approval policy is not a complete data-exfiltration
boundary. Treat imported HTML as executable content when opening it in Ox.

The native bridge accepts only messages from the current main document, validates
exact function names and input schemas, and bounds request, response, queue, and
rate budgets. Canvas cannot call other `ox.*` namespaces or arbitrary VM evaluation.
Closing or replacing the document cancels its work and invalidates late
replies; it cannot roll back a completed external action. Native prompts and
logs identify the canvas caller. Credentials stay in Host service runtimes.

The renderer retains a restrictive content-security policy: direct network
requests, remote scripts, frames, forms, and browser device access remain blocked.
Its private resource scheme serves only bounded sibling media. Only the initial
artifact document and its fragment links may navigate inside the view. External
HTTP, HTTPS, mail, and telephone links open only from a user link activation.
The map bridge accepts bounded coordinates and returns a raster snapshot.
Service-produced files use bounded temporary storage. They are not silently
imported into a Profile and are removed when the canvas closes.

**Residual risk:** model-generated or imported canvas code can misuse any service
operation allowed by the user's existing policy. WebKit process isolation and OS
security updates remain part of the boundary. Service results inserted into the
DOM as HTML can introduce script execution; authoring guidance requires rendering
untrusted text as text.

### T11 — Agent-written persistent skill instructions
The model writes misleading instructions into a user skill or tries to use a
skill edit to escape the active Profile. **Mitigation:** skill actions accept only
validated structured fields and canonical names, resolve beneath the immutable
active-Profile scope, and never accept or return filesystem paths. Saving a skill
does not select it, attach services, or execute actions; the user must later
invoke it explicitly, and every resulting service action keeps its native
approval policy. Service and page content remain untrusted and the system prompt
forbids persisting them as skills without an explicit user request. **Residual
risk:** an adversarial model can alter or remove user-authored skill text without
a separate confirmation, matching the product decision that skill edits are
content changes rather than actions.

### T12 — Scheduled skill executes changed or unapproved future work
The model schedules persistent instructions or later edits a skill so future
execution differs from what the user authorized. **Mitigation:** schedules are
device-owned records bound to one Profile and store a frozen user-skill snapshot,
argument, and recurrence. Creating, enabling, disabling, deleting, or manually
running a schedule through the agent requires a native one-time confirmation that
cannot become a standing approval. Editing the source skill never changes the
snapshot. A scheduled run retains every normal service, Files, private-data,
authentication, and payment boundary; work that needs an interactive answer stops
and notifies the user. **Residual risk:** iOS controls background launch timing and
may delay or terminate an occurrence; previously granted standing action approvals
remain effective during scheduled runs until the user revokes them.

## Out of scope

- **A user attacking their own device.** Ox is local-first; a person who
  roots their own phone is not in the threat model.
- **A site changing its own UI or API.** This breaks a service functionally, not
  a security boundary; it is handled by registry updates and changed-domain
  detection. Reproducible per-chat commit pinning remains future work.
- **Denial of service and resource exhaustion.**
- **Server-side authorization.** The Server is stateless by design — it holds no
  per-client identity and enforces no per-user policy; all trust decisions are
  made on-device.

## Reporting

This project does not yet run a formal vulnerability-disclosure process. When
the registry and client are published for external use, a disclosure policy and
contact will be added here.
