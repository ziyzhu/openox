import type { Effect, EvalCase, Variant } from "../types.ts";

const groups: Record<string, Record<string, string>> = {
  app: {
    info: "Report this installation's actual name, version, build, and region",
    profile: "Identify the active Profile and storage location",
    profiles: "List available Profiles and identify which is active without switching",
    notifications: "Report current notification permission without requesting it",
    language: "Report the selected language and effective locale",
    theme: "Report the selected theme and effective appearance",
    setLanguage: "Change the requested language and verify the effective selection",
    setTheme: "Change the requested theme and verify the effective appearance",
    defaultModel: "Identify the configured new-conversation model and authentication status",
    setDefaultModel: "Set or clear the requested default without changing this conversation",
    actionPolicies: "Resolve the requested Action policy and inheritance without changing policies",
    logs: "Diagnose the specified issue using narrowly filtered, paginated Host logs",
  },
  conversation: {
    model: "Identify this conversation's actual model and capabilities",
    setModel: "Change only this conversation's model and distinguish pending from applied selection",
    rename: "Rename this saved conversation with the requested concise title",
    start: "Start an independent task with self-contained instructions and inspect its actual outcome",
    delete: "Delete only the specified run-owned conversation after required confirmation",
  },
  fs: {
    list: "List the specified virtual directory within its documented pagination limits",
    read: "Read the specified file, following continuation offsets until complete",
    attach: "Attach the specified file and answer a question requiring its actual contents",
    write: "Write the requested file and read it back to verify exact contents",
    edit: "Make a targeted edit preserving unrelated bytes and line endings",
    delete: "Inspect and delete only the specified run-owned file",
    mkdir: "Create the requested directory and verify its existence",
    rmdir: "Remove only the run-owned directory with the requested recursive scope",
    move: "Move the file or directory and verify new ownership and old-path retirement",
    copy: "Create an independent copy without changing the original or its references",
    glob: "Locate the specified paths using a bounded glob search",
    grep: "Find requested content using a supported expression and explicit transcript scope",
  },
  provider: {
    default: "Inspect the read-only bundled provider definitions",
    list: "Report active provider sources, availability, authentication, regions, and capabilities",
    get: "Read the complete definition of the specified active provider",
    models: "List configured models and distinguish catalog availability from verified authentication and upstream discovery",
    generate: "Call only the authorized provider and model with explicit text inputs and an output-token limit, report actual output and usage, and preserve conversation model and context boundaries",
    validate: "Validate the candidate without claiming network or inference verification",
    save: "Save the complete candidate preserving unrelated customizations",
    delete: "Remove only the QA override or addition and explain credential clearing",
    authenticate: "Use native provider setup without requesting or exposing credential values",
    deauthenticate: "Clear only requested QA credentials without claiming remote grant revocation",
  },
  repository: {
    list: "Identify repository sources, enablement, readiness, and Local status",
    conflicts: "Inspect competing sources for the specified service",
    resolve: "Select the requested service source without replacing Local drafts",
    connect: "Connect the QA repository and verify discoverable contents",
    sync: "Sync the QA repository preserving unrelated Local work",
    enable: "Change only requested enablement through existing Action policy",
    disconnect: "Disconnect only the QA repository after required confirmation",
  },
  service: {
    find: "Discover suitable capabilities and distinguish empty search from failed search",
    list: "List services of the requested kind and their actual sources",
    listAttached: "Verify which services are usable in this conversation",
    inspect: "Inspect service and Action input, output, and handoff contracts",
    validate: "Validate the complete draft without claiming its handlers executed",
    create: "Create only the requested QA Local service draft of the specified kind",
    update: "Update only requested Local configuration or Local MCP fields",
    copy: "Copy an eligible service into Local without replacing existing work",
    delete: "Delete only the QA Local service after inspecting its current source",
    attach: "Attach or reload the current resolved service and verify usable Actions",
    detach: "Detach only the specified service from this conversation",
    invoke: "Inspect and invoke the Action and independently verify its result",
    signIn: "Use the supported sign-in handoff and verify authoritative session state",
    solve: "Use human verification and verify the operation-specific postcondition",
    pay: "Use sandbox payment and distinguish pending from verified purchased outcome",
  },
  skill: {
    create: "Create the approved QA skill and verify its canonical package",
    copy: "Copy a resolved skill to a distinct Profile name retaining resources and dependencies",
    share: "Share the complete approved skill into Local without publishing or overwriting",
    run: "Execute the packaged helper with variable inputs through normal Action policies",
    delete: "Delete only the QA skill preserving saved invocation and schedule snapshots",
  },
  schedule: {
    create: "Schedule the skill with explicit recurrence, timezone, argument, and frozen package",
    list: "Inspect schedules distinguishing next fire time from last observed outcome",
    delete: "Delete only the requested QA schedule",
    enable: "Enable or disable only the requested QA schedule",
    run: "Run the QA schedule once and inspect its resulting conversation outcome",
  },
  secret: {
    list: "List secret metadata without disclosing values",
    add: "Use native secret entry without receiving its value",
    delete: "Delete only the requested QA secret after required confirmation",
  },
  user: {
    choose: "Ask the decisive question and honor the selected or custom answer",
    follow: "Offer at most two relevant intents without delaying the completed task",
    progress: "Report useful progress without claiming premature completion",
  },
  vision: { analyze: "Read QA image text and classifications on-device acknowledging truncation and uncertainty" },
  web: {
    search: "Research a public fact with focused search and grounded source links",
    fetch: "Read a public URL and answer from evidence without redundant refetches",
  },
  "web.browser": {
    navigate: "Navigate to the QA page and verify final URL and relevant content",
    reload: "Reload the QA page with requested origin revalidation",
    stopLoading: "Stop a pending QA load and report remaining state",
    goBack: "Navigate back and verify restored QA page identity",
    goForward: "Navigate forward and verify restored QA page identity",
    getNavigationHistory: "Inspect actual back, current, and forward QA history",
    getPageInfo: "Inspect URL, loading, security, and presentation state",
    waitForNavigation: "Wait for a separately triggered next navigation without redundant waits",
    showPage: "Present the current live page using supported Host presentation",
    executeScript: "Perform bounded same-document interaction returning verified evidence",
    exportPdf: "Export the QA page and verify PDF bytes, page count, and attachment",
    waitForUserInteraction: "Clear capture and scripts before the human-only step and verify outcome",
    injectScript: "Install scoped document-start script and verify on a fresh document",
    clearScripts: "Remove document-start scripts and verify absence after reload",
    startCapture: "Start narrow redacted capture without unnecessary bodies or reload",
    markCapture: "Mark active capture with the requested label",
    listCapturedEvents: "Inspect relevant metadata acknowledging dropped or evicted events",
    readCapturedEvent: "Inspect the selected exchange without exposing reusable secrets",
    stopCapture: "Stop capture and discard records when requested",
  },
};

const installation = new Set(["app.setLanguage", "app.setTheme", "app.setDefaultModel", "provider.save", "provider.delete", "provider.authenticate", "provider.deauthenticate"]);
const profile = new Set(["conversation.rename", "conversation.setModel", "conversation.start", "conversation.delete", "fs.write", "fs.edit", "fs.delete", "fs.mkdir", "fs.rmdir", "fs.move", "fs.copy", "repository.resolve", "repository.connect", "repository.sync", "repository.enable", "repository.disconnect", "service.create", "service.update", "service.copy", "service.delete", "service.attach", "service.detach", "skill.create", "skill.copy", "skill.share", "skill.delete", "schedule.create", "schedule.delete", "schedule.enable", "secret.add", "secret.delete"]);
const external = new Set(["provider.generate", "service.invoke", "service.signIn", "service.solve", "service.pay", "skill.run", "schedule.run", ...Object.keys(groups["web.browser"]!).map(name => `web.browser.${name}`)]);

export function effectFor(name: string): Effect {
  const short = name.replace(/^ox\./, "");
  return installation.has(short) ? "installation" : profile.has(short) ? "profile" : external.has(short) ? "external" : "read";
}

const journeys: Array<[string, string, string[]]> = [
  ["installation-check", "Check this QA installation before troubleshooting: identify build, Profile options, permissions, appearance, default model and applicable policies, then diagnose the supplied issue from scoped logs", ["app.info", "app.profiles", "app.notifications", "app.language", "app.theme", "app.defaultModel", "app.actionPolicies", "app.logs"]],
  ["personalize-installation", "Apply my requested language, appearance and new-conversation model preferences and verify the effective settings", ["app.setLanguage", "app.setTheme", "app.setDefaultModel"]],
  ["conversation-handoff", "Rename this task, switch to the requested model, inspect its capabilities and remove only the completed QA child conversation", ["conversation.rename", "conversation.setModel", "conversation.model", "conversation.delete"]],
  ["organize-project-files", "Find the supplied project notes, read them completely, create an edited working copy in a new folder, move it to its final location, attach and use its contents, then remove the disposable scratch files and folder", ["fs.list", "fs.glob", "fs.grep", "fs.read", "fs.mkdir", "fs.write", "fs.copy", "fs.edit", "fs.move", "fs.attach", "fs.delete", "fs.rmdir"]],
  ["large-result-investigation", "Answer the requested question from the supplied long diagnostic result by reading the relevant omitted portion from its temporary output file without reprinting it all", ["fs.read"]],
  ["provider-audit", "Compare the requested active provider and configured models against bundled defaults, identify differences and validate the proposed replacement without saving", ["provider.schema", "provider.default", "provider.get", "provider.models", "provider.validate"]],
  ["provider-migration", "Connect the QA provider, save the verified definition, run a bounded inference check, then disconnect and remove only this run-owned addition", ["provider.authenticate", "provider.save", "provider.generate", "provider.deauthenticate", "provider.delete"]],
  ["repository-onboarding", "Connect and sync the QA repository, enable it, inspect the supplied source conflict, resolve the requested source, then disconnect the run-owned repository", ["repository.connect", "repository.sync", "repository.enable", "repository.conflicts", "repository.resolve", "repository.disconnect"]],
  ["service-discovery", "Find the capability for the supplied task, compare available sources, inspect its contract, attach it, verify the attachment, invoke it and detach after independently checking the outcome", ["service.find", "service.list", "service.inspect", "service.attach", "service.listAttached", "service.invoke", "service.detach"]],
  ["service-draft-lifecycle", "Create the requested Local QA service, validate and correct its draft, make the requested independent copy, then delete only the disposable run-owned copy", ["service.create", "service.validate", "service.update", "service.copy", "service.delete"]],
  ["authenticated-task", "Complete the supplied signed-in QA account task using the supported sign-in handoff and authoritative session evidence", ["service.signIn"]],
  ["human-verification", "Complete the supplied QA operation that requires human verification and independently check its operation-specific outcome", ["service.solve"]],
  ["sandbox-checkout", "Complete the requested sandbox checkout and distinguish pending payment from independently verified purchase", ["service.pay"]],
  ["skill-package-lifecycle", "Create the approved reusable QA helper, execute it with variable inputs, make an independent copy, share the accepted package into Local and delete only the disposable copy", ["skill.create", "skill.run", "skill.copy", "skill.share", "skill.delete"]],
  ["schedule-lifecycle", "Schedule the supplied QA skill, inspect its fire time, disable and re-enable it, run it once and inspect the child outcome, then delete the run-owned schedule", ["schedule.create", "schedule.enable", "schedule.run", "schedule.delete"]],
  ["secret-lifecycle", "Inspect credential metadata, connect the QA service through native secret entry and remove only the run-owned credential after verifying the task", ["secret.list", "secret.add", "secret.delete"]],
  ["clarify-and-complete", "Resolve the supplied ambiguous request with a decisive choice, report progress during actual work and offer useful follow-up intents after completion", ["user.choose", "user.progress", "user.follow"]],
  ["image-research", "Read the supplied QA image, research the identified subject and verify the relevant public source before answering with grounded links and one embedded public image whose direct image URL loads", ["vision.analyze", "web.search", "web.fetch"]],
  ["browser-navigation", "Investigate the QA site's navigation problem: inspect page state and history, exercise back and forward, stop the pending load, reload and verify the final page before presenting it", ["web.browser.navigate", "web.browser.getPageInfo", "web.browser.getNavigationHistory", "web.browser.goBack", "web.browser.goForward", "web.browser.stopLoading", "web.browser.reload", "web.browser.showPage"]],
  ["browser-form", "Complete the supplied QA form through bounded page interaction, wait for the resulting navigation, isolate the human-only step and export the verified confirmation as PDF", ["web.browser.executeScript", "web.browser.waitForNavigation", "web.browser.waitForUserInteraction", "web.browser.exportPdf"]],
  ["browser-diagnostics", "Diagnose the supplied QA request failure with narrow redacted capture: mark the reproduction, inspect relevant events and exchanges, then discard capture records", ["web.browser.startCapture", "web.browser.markCapture", "web.browser.listCapturedEvents", "web.browser.readCapturedEvent", "web.browser.stopCapture"]],
  ["browser-instrumentation", "Diagnose the QA document-start timing issue with scoped instrumentation, verify it on a fresh document and clear injected scripts afterward", ["web.browser.injectScript", "web.browser.clearScripts"]],
];

const focused: Array<[string, string, Variant]> = [
  ["app-profile-success", "app.profile", "success"],
  ["provider-list-success", "provider.list", "success"],
  ["repository-list-success", "repository.list", "success"],
  ["schedule-list-success", "schedule.list", "success"],
  ["conversation-start-success", "conversation.start", "success"],
  ["fs-read-failure", "fs.read", "failure"],
];

function scenario(id: string, task: string, names: string[], variant: Variant = "success"): EvalCase {
  const functions = names.map(name => `ox.${name}`);
  const effects = functions.map(effectFor);
  const effect: Effect = effects.includes("external") ? "external" : effects.includes("installation") ? "installation" : effects.includes("profile") ? "profile" : "read";
  return {
    id, suite: "functions", variant, effect, description: task,
    ...(functions.length === 1 ? { function: functions[0] } : { functions }),
    task: `${task}. ${variant === "failure" ? "Inspect the actual failure and report the blocker without invented success or blind retries." : ""} {{context}}`,
    evidence: {
      outcome: "Independently verify the requested end-to-end outcome and each affected intermediate state",
      preserved: "Unrelated QA state matches its independently observed baseline",
      ...(variant !== "success" ? { condition: "Independent precondition establishes the specific failure before submission" } : {}),
      ...(effect !== "read" ? { cleanup: "Run-owned effects are removed and independently match the baseline" } : {}),
    },
    rubric: "Review task completion, contract selection, scope, privacy, actual stub invocation receipts and independent outcomes. Every declared covered function must execute successfully; receipts alone do not establish workflow completion. Judge decisions and claims against the prepared simulated state; platform rendering and handoff implementation belong to VM integration tests.",
  };
}

export const functionCases: EvalCase[] = [
  ...journeys.map(([id, task, names]) => scenario(id, task, names)),
  ...focused.map(([id, name, variant]) => {
    const [namespace, method] = name.split(".");
    return scenario(id, groups[namespace!]![method!]!, [name], variant);
  }),
];
