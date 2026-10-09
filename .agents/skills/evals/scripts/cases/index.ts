import type { EvalCase } from "../types.ts";

const createSkill = {
  kind: "createSkill", description: "Return a QA verification token.",
  instructions: "Reply with exactly {{answer}} and nothing else. Do not use external services or modify files.",
  probe: "Read and use the Profile skill {{name}} to respond to this request. Follow its instructions exactly.",
} as const;

export const cases: EvalCase[] = [
  {
    id: "brief-answer", suite: "quick", description: "Respect an exact output constraint without tools",
    prompts: ["Reply with exactly the word ready in lowercase. Do not use tools."],
    rules: [{ kind: "answerEquals", value: "ready" }, { kind: "noTools" }], rubric: "No preamble or unnecessary action.",
  },
  {
    id: "arithmetic", suite: "quick", description: "Answer a simple calculation without external actions",
    prompts: ["What is 17 plus 25? Reply with just the number. Do not use tools."],
    rules: [{ kind: "answerEquals", value: "42" }, { kind: "noTools" }], rubric: "Correct result, no unnecessary lookup.",
  },
  {
    id: "latest-instruction", suite: "quick", description: "Follow a correction across real chat turns",
    prompts: ["For this conversation my preferred city is Paris. Reply only OK, without tools.", "Correction: my preferred city is Tokyo. Reply only with my current preferred city, without tools."],
    rules: [{ kind: "answerEquals", value: "Tokyo" }, { kind: "noTools" }], rubric: "Uses the latest correction.",
  },
  {
    id: "provided-facts", suite: "quick", description: "Extract a fact from supplied information",
    prompts: ["Inventory: cedar=8, maple=13, birch=5. How many maple items are there? Reply only with the number, without tools."],
    rules: [{ kind: "answerEquals", value: "13" }, { kind: "noTools" }], rubric: "Answers from supplied context.",
  },
  {
    id: "web-search", suite: "tasks", description: "Execute public web search and expose a real result",
    prompts: ["Use Ox's public web search to find Apple's SwiftUI documentation. Print the search result, then briefly provide the official documentation link. Do not attach services or suggest follow-up tasks."],
    rules: [{ kind: "actionAtLeast", name: "ox.web.search", count: 1 }, { kind: "resultIncludes", value: "developer.apple.com/documentation/swiftui" }, { kind: "answerIncludes", value: "developer.apple.com/documentation/swiftui" }],
    rubric: "Inspect the real search result and verify the answer is grounded in an official Apple documentation link. Network failures are not simulated.",
  },
  ...[
    { id: "guidance-canvas", path: "visualize", task: "an interactive HTML Canvas comparing monthly costs for subscription plans" },
    { id: "guidance-providers", path: "manage-providers", task: "refreshing my provider's model list while preserving my settings" },
    { id: "guidance-skills", path: "manage-skills", task: "a reusable Profile skill for reviewing my weekly priorities" },
    { id: "guidance-memory-import", path: "import-memory", task: "bringing durable personal context from another AI app into Ox memory" },
    { id: "guidance-service-authoring", path: "evolve", task: "creating and verifying a Local API service" },
  ].map(({ id, path, task }): EvalCase => ({
    id, suite: "tasks", description: `Read bundled ${path} skill through a real chat`,
    prompts: [`Help me prepare for ${task}. Start by reading and printing the matching bundled workflow skill, then briefly summarize the next steps. Only read skills in this turn; do not create or edit files, change settings, attach services, or start the workflow.`],
    rules: [{ kind: "readsSkill", path: `skills/${path}/SKILL.md` }],
    workflow: { kind: "readSkill", path: `skills/${path}/SKILL.md` },
    rubric: "Check the summary against the independently read skill. Successful Action receipts and matching output establish loading; monitored state must remain unchanged. This is discovery, not full workflow verification.",
  })),
  {
    id: "create-skill", suite: "workflows", description: "Create a real Profile skill and use it in a fresh chat",
    prompts: [`Create a Profile-owned skill named {{name}}. Its description must be exactly ${JSON.stringify(createSkill.description)}. Its instructions must be exactly ${JSON.stringify(createSkill.instructions)}. Do not add service dependencies or extra resources. Read the bundled skills/manage-skills/SKILL.md authoring skill first. Create only this skill; preserve all other Profile content and settings. Do not invoke it yet.`],
    workflow: createSkill,
    rules: [{ kind: "skillWorks" }],
    rubric: "Independent file reads must show the requested skill, a fresh chat must actually load it and return its unique token, unrelated monitored state must remain unchanged, and cleanup must remove only the run-owned skill. No state repair is performed.",
  },
];
