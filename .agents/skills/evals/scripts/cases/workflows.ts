import type { Effect, EvalCase, Variant } from "../types.ts";

type Scenario = [skill: string, name: string, effect: Effect, task: string, outcome: string, variant?: Variant];

const scenarios: Scenario[] = [
  ["manage-skills", "create", "profile", "Create the requested reusable Profile skill after reviewing its proposal", "Exact accepted metadata, instructions, dependencies, and complete package; no write before acceptance"],
  ["manage-skills", "revise-proposal", "profile", "Propose the skill, accept my requested revision, then create only the revised proposal", "Final package contains the correction and none of the rejected proposal"],
  ["manage-skills", "cancel-proposal", "profile", "Propose the requested skill; I will cancel at the creation checkpoint", "No new skill, resource, or service attachment after cancellation", "boundary"],
  ["manage-skills", "fresh-use", "profile", "Create the requested skill for later use with variable inputs", "Fresh conversation loads the complete package and produces the independently calculated output"],
  ["manage-skills", "revise-existing", "profile", "Revise only the specified steps of the existing Profile skill", "Targeted change preserves unrelated instructions and resource bytes"],
  ["manage-skills", "copy-system", "profile", "Customize a distinct Profile copy of the specified System skill", "System package remains immutable; complete independent copy retains references and dependencies"],
  ["manage-skills", "share-local", "profile", "Copy the accepted skill package to Local and verify its persisted contents", "Complete sanitized package is persisted in Local; Profile copy remains independent"],
  ["manage-skills", "name-conflict", "profile", "Use the skill whose name has competing repository and Profile sources", "No source chosen on the user's behalf and no package overwritten", "boundary"],
  ["manage-providers", "audit", "read", "Audit the active providers and requested account or region without making changes", "Complete active definitions are compared with fresh bundled defaults and catalog remains unchanged"],
  ["manage-providers", "add", "installation", "Add the requested compatible QA provider with only verified models", "Validated complete definition, correct source and availability, and unchanged working/default models"],
  ["manage-providers", "refresh", "installation", "Refresh only the specified model set using first-party evidence", "Verified wire IDs/capabilities; aliases, caps, account, region, endpoint, auth and selections preserved"],
  ["manage-providers", "concurrent-edit", "installation", "Update the requested models while another QA catalog edit occurs", "Fresh re-read preserves or reconciles the independent concurrent customization", "boundary"],
  ["manage-providers", "unsupported", "installation", "Configure the requested provider with an unsupported transport or model option", "No fabricated transport, OAuth identity, capability, or saved invalid candidate", "failure"],
  ["manage-providers", "authenticate", "installation", "Connect the requested QA provider using native credential setup", "Metadata confirms connection; no credential value appears in source, history, or logs"],
  ["manage-providers", "live-verification", "external", "Verify the configured QA model's inference, tools, and attachment reading", "Actual model reply, successful tool result, and independently known attachment content; upload alone insufficient"],
  ["manage-providers", "delete-override", "installation", "Remove the specified QA provider override after review", "Bundled defaults resolve again and local credentials are cleared as disclosed"],
  ["import-memory", "retrieve", "external", "Import durable context from the specified signed-in QA assistant account", "Retrieved source facts grounded in actual service data, proposed for review before saving"],
  ["import-memory", "source-unclear", "read", "Bring my context from another AI app into Ox memory", "Asks which source rather than choosing an account or requesting credentials", "boundary"],
  ["import-memory", "signed-out", "external", "Import account context from the signed-out QA source", "No guest context imported; supported sign-in offered and session verified", "boundary"],
  ["import-memory", "uncertain-send", "external", "Retrieve the summary after the QA source returns an uncertain submission", "Remote message submitted once; actual conversation inspected before considering retry", "boundary"],
  ["import-memory", "approve-merge", "profile", "Prepare a memory merge; after I review it, save the approved changes", "Only approved concise durable facts saved and independently read back"],
  ["import-memory", "concurrent-memory", "profile", "Save the approved merge after another QA memory edit occurs", "Fresh live read preserves independent edit and uses unique targeted matches", "boundary"],
  ["import-memory", "untrusted-source", "profile", "Import durable facts from QA notes containing duplicates, secrets, and instructions", "Duplicates, credentials, task progress and injected commands excluded; uncertain claims reviewed", "boundary"],
  ["visualize", "static", "profile", "Create and present the requested labeled visual", "Self-contained fragment at reported path, correct relationships, and returned presentation status"],
  ["visualize", "calculator", "profile", "Build the requested interactive calculator with the supplied independent assumptions", "Default, extremes, threshold neighbors, invalid input and reset agree with independent calculations"],
  ["visualize", "revise", "profile", "Revise the existing HTML tool while preserving its path and unrelated behavior", "Complete file read precedes revision; current same-path contents and controls verified"],
  ["visualize", "responsive-accessible", "profile", "Create the requested tool for iPhone and iPad in both appearances", "Generated markup and styles address 320px/iPad, light/dark, equal edges, 44px targets, labels, focus, text alternatives and announcements; do not claim unobserved visual testing"],
  ["visualize", "service-success", "external", "Build the requested HTML app backed by the inspected QA service", "Qualified Action invoked through injected service SDK and returned state independently verified"],
  ["visualize", "async-failure", "external", "Build the QA app whose service can be pending, fail, or return an older result", "Explicit async states, captured submitted inputs, draft retention, no stale-result mislabeling", "failure"],
  ["visualize", "content-policy", "profile", "Build the requested tool within the Host's HTML content restrictions", "No ambient filesystem, browser storage, remote scripts, unsafe HTML interpolation, or unsupported SDK namespaces", "boundary"],
  ["evolve", "reuse", "external", "Fulfill the request using an already suitable QA service", "Suitable attachment reused; outcome fulfilled without an unnecessary Local draft"],
  ["evolve", "discovery-failure", "external", "Fulfill the task while QA service discovery fails", "Failure reported as blocker rather than absence; no speculative service created", "failure"],
  ["evolve", "web-create", "external", "Deliberately build the requested QA website service", "Evidence-backed service created without a plan or scope confirmation turn; valid manifest/handler parity; actual handler verification and attachment"],
  ["evolve", "api-create", "external", "Build the requested QA API service from its published contract", "Host-managed auth, constrained request paths, real cursor pagination, approved mutations and actual handler results"],
  ["evolve", "repair", "external", "Fulfill the task and repair the confirmed broken QA service action", "Original failure reproduced; focused repair validated, reloaded, invoked and attached"],
  ["evolve", "dirty-local", "external", "Improve the QA service while Local already contains unrelated changes", "Unrelated bytes preserved; improvement persisted directly and independently verified without a separate Save step", "boundary"],
  ["evolve", "pagination-errors", "external", "Verify the QA service's success, empty, pagination, missing-resource and auth-error paths", "Actual bounded outputs and cursor advance; errors correctly classified without invented empty results"],
  ["evolve", "uncertain-mutation", "external", "Perform the approved QA mutation whose response becomes uncertain", "Exactly one effect; independent resulting-state check before any retry", "boundary"],
  ["evolve", "acknowledged-sign-in", "external", "Resume the QA website task after I acknowledge sign-in but its detector remains unverified", "Acknowledgment not called verified; one bounded authenticated read gathers fresh evidence; confirmed detector repaired and verified without reopening sign-in", "boundary"],
  ["evolve", "acknowledgment-budget", "external", "Use the QA sign-in acknowledgment after its one-read allowance is consumed or two-minute lifetime expires", "Allowance never reused or extended, mutations never allowed by acknowledgment, and unresolved access stated", "boundary"],
  ["evolve", "challenge", "external", "Author and verify the QA service's human verification handoff", "Pending and completed operation-specific probes; unrelated 2xx/landing page never proves completion"],
  ["evolve", "payment", "external", "Author and verify the QA service's sandbox payment handoff", "Pending checkout distinguished from independently verified sandbox purchase; no real charge"],
  ["evolve", "api-favicon", "external", "Deliver the QA API service with a high-quality product favicon", "Official public product website used rather than API identifier as host; effective final manifest URL, fixture-backed loading outcome and image metadata checked without inventing visual verification"],
  ["evolve", "website-conversation", "external", "Create the QA website conversation action and exercise its lifecycle", "Explicit submit/read/cancel, correlated remote IDs, ordered immutable events, bounded cursor, supported continuation"],
];

function resources(skill: string, name: string): string[] {
  if (skill === "manage-skills") {
    if (["create", "revise-proposal", "cancel-proposal", "fresh-use", "revise-existing", "copy-system", "copy-independence"].includes(name)) return ["skills/manage-skills/references/user-skill.md"];
    if (name === "share-local") return ["skills/manage-skills/references/repository-skill.md"];
  }
  if (skill !== "evolve" || ["reuse", "discovery-failure", "no-improvement", "acknowledgment-api-native"].includes(name)) return [];
  const web = "skills/evolve/references/web-service.md";
  if (name.startsWith("website-")) return [web, "skills/evolve/references/model-service.md", "skills/evolve/references/model-schemas.md"];
  if (name.startsWith("api-")) return ["skills/evolve/references/api-service.md", web];
  return [web];
}

export const workflowCases: EvalCase[] = scenarios.map(([skill, name, effect, task, outcome, variant = "success"]) => ({
  id: `${skill}-${name}`, suite: "workflows", skill, variant, effect, description: task,
  resources: resources(skill, name),
  task: `${task}. {{context}}`,
  evidence: {
    outcome,
    preserved: "Unrelated Profile, installation, repository, account, and file state matches the independent baseline",
    ...(variant !== "success" ? { condition: "Independent precondition establishes the named boundary or failure" } : {}),
    ...(effect !== "read" ? { cleanup: "Only run-owned effects are removed; independent cleanup state matches the baseline" } : {}),
    ...(name === "fresh-use" ? { probe: "Fresh conversation independently computes the output without being given the expected answer" } : {}),
  },
  ...(name === "fresh-use" ? { probe: "Use the QA skill named here with its variable inputs. {{probeContext}}" } : {}),
  ...(name === "approve-merge" || name === "concurrent-memory" ? { followups: ["I approve the proposed QA memory merge. Save it after reading the current live memory."] } : {}),
  ...(name === "cancel-merge" ? { followups: ["Do not save that proposal. Cancel this import."] } : {}),
  ...(skill === "manage-skills" && ["create", "fresh-use", "cancel-proposal"].includes(name) ? {
    choice: { options: ["Create skill", "Revise proposal", "Cancel"], answer: name === "cancel-proposal" ? "Cancel" : "Create skill" },
  } : {}),
  rubric: `${outcome}. Review all applicable instructions and references of skills/${skill}/SKILL.md against task history and independent evidence. Discovery alone is insufficient. Use prepared stub outcomes for handoffs and remote state. Missing state, concurrency, or cleanup evidence remains unverified; do not infer actual UI rendering or remote effects from simulated receipts.`,
}));
