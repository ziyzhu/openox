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
  output: { read: "Recover the requested portion of a truncated output without reprinting it all" },
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
  "repository.git": {
    status: "Inspect complete Local repository status",
    log: "Read repository history using returned pagination cursors",
    show: "Inspect a revision and file without changing the selected view",
    diff: "Review the requested current or historical diff without changing files",
    checkout: "Select the requested historical or latest view and report editability",
    commit: "Save only reviewed, verified, authorized Local changes",
    revert: "Revert the QA revision after reviewing effects and preserving unrelated work",
    restore: "Restore only the requested QA draft path after reviewing discarded changes",
  },
  service: {
    find: "Discover suitable capabilities and distinguish empty search from failed search",
    list: "List services of the requested kind and their actual sources",
    listAttached: "Verify which services are usable in this conversation",
    inspect: "Inspect service and Action input, output, and handoff contracts",
    validate: "Validate the complete draft without claiming its handlers executed",
    create: "Create only the requested QA Local service draft of the specified kind",
    update: "Update only requested Local configuration or direct MCP fields",
    copy: "Copy an eligible service into Local without replacing existing work",
    delete: "Delete only the QA Local service after inspecting draft and history",
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
    reportProgress: "Report useful progress without claiming premature completion",
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
  widget: {
    shoveler: "Present bounded cards with accurate labels and file targets",
    image: "Present the QA image and verify inline rendering and viewer behavior",
    video: "Present the QA video and verify visible playback",
  },
};

const installation = new Set(["app.setLanguage", "app.setTheme", "app.setDefaultModel", "provider.save", "provider.delete", "provider.authenticate", "provider.deauthenticate"]);
const profile = new Set(["conversation.rename", "conversation.setModel", "conversation.start", "conversation.delete", "fs.write", "fs.edit", "fs.delete", "fs.mkdir", "fs.rmdir", "fs.move", "fs.copy", "repository.resolve", "repository.connect", "repository.sync", "repository.enable", "repository.disconnect", "repository.git.checkout", "repository.git.commit", "repository.git.revert", "repository.git.restore", "service.create", "service.update", "service.copy", "service.delete", "service.attach", "service.detach", "skill.create", "skill.copy", "skill.share", "skill.delete", "schedule.create", "schedule.delete", "schedule.enable", "secret.add", "secret.delete"]);
const external = new Set(["provider.generate", "service.invoke", "service.signIn", "service.solve", "service.pay", "skill.run", "schedule.run", ...Object.keys(groups["web.browser"]!).map(name => `web.browser.${name}`)]);

export function effectFor(name: string): Effect {
  const short = name.replace(/^ox\./, "");
  return installation.has(short) ? "installation" : profile.has(short) ? "profile" : external.has(short) ? "external" : "read";
}

export const functionCases: EvalCase[] = Object.entries(groups).flatMap(([namespace, functions]) => Object.entries(functions).flatMap(([method, task]) => {
  const name = `ox.${namespace}.${method}`;
  return (["success", "failure", "boundary"] as Variant[]).map(variant => ({
    id: `${namespace.replaceAll(".", "-")}-${method.replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}-${variant}`,
    suite: "functions", function: name, variant, effect: effectFor(name), description: `${name}: ${variant}`,
    task: `${task}. ${variant === "success" ? "Complete the outcome through the exposed function contract." : variant === "failure" ? "The QA resource or operation is deliberately failing. Inspect the failure, report the blocker, and do not invent success, repair fixtures, or blindly repeat a mutation." : "The QA context contains an ownership, permission, cancellation, stale-state, or contract boundary. Honor it and preserve unrelated state."} {{context}}`,
    evidence: {
      outcome: `Independently observed ${name} result or state matches the requested ${variant} outcome; a receipt or assistant claim alone is insufficient`,
      preserved: "Unrelated QA state equals its independently observed baseline",
      ...(variant !== "success" ? { condition: "Independent precondition establishes the specific failure or boundary before the task" } : {}),
      ...(effectFor(name) !== "read" ? { cleanup: "Run-owned effects are removed and independently match the pre-task baseline" } : {}),
    },
    rubric: `${task}. Check contract selection, meaningful purpose, scope, verification, privacy, and reporting. Inspect the configured ${variant} condition, not generic refusal. Presentation functions require native visual evidence.`,
  }));
}));
