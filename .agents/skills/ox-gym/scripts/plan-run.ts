import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";

type Mode = "explore" | "compare" | "stress";

type Options = {
  mode: Mode;
  sessions: number;
  seed: string;
  targets: string[];
  devices: string[];
  appLanguages: string[];
  extraDimensions: Record<string, string[]>;
  authorizeReal: boolean;
  maximumProviderCalls: number;
  previous: string[];
};

type Intent = {
  id: string;
  mockIntent: string;
  prompts: Record<"en" | "zh-Hans" | "mixed", string[]>;
  success: string;
  responseShape: string;
  mockOnly?: boolean;
};

type Assignment = {
  persona: Record<string, string>;
  intent: Intent;
  environment: Record<string, string>;
};

type PlannedSession = {
  id: string;
  pairID?: string;
  wave: number;
  seed: number;
  simulator: string;
  providerTarget: string;
  persona: Record<string, string>;
  intent: { id: string; success: string };
  prompts: string[];
  environment: Record<string, string>;
  budgets: {
    wallClockSeconds: number;
    explorationCutoffSeconds: number;
    completionCutoffSeconds: number;
    maximumSteps: number;
    maximumRetries: number;
    maximumProviderCalls: number;
  };
  materializationStatus: "required" | "ready";
  providerVerification: "required" | "verified";
  providerCallsAuthorized: boolean;
  executionAuthorized: boolean;
  setup: string[];
  plannedActions: string[];
  allowedEffects: { modelProviderCalls: boolean; realProviderCalls: boolean; externalMutation: false; credentialAccess: false };
  evidenceDirectory: string;
};

const intents: Intent[] = [
  {
    id: "quick-answer",
    mockIntent: "17",
    prompts: {
      en: ["In two short paragraphs, explain why leaves change color."],
      "zh-Hans": ["请用两个简短段落解释树叶为什么会变色。"],
      mixed: ["请用 two short paragraphs 解释树叶为什么会变色。"],
    },
    success: "A concise useful answer becomes visible and completes coherently",
    responseShape: "shortStreamingText",
  },
  {
    id: "structured-planning",
    mockIntent: "10",
    prompts: {
      en: ["Create a concise three-step plan for organizing a small community picnic."],
      "zh-Hans": ["请为组织一次小型社区野餐制定一个简洁的三步计划。"],
      mixed: ["请给我一个 concise three-step plan 来组织小型社区野餐。"],
    },
    success: "A readable structured plan appears without layout or streaming defects",
    responseShape: "structuredText",
  },
  {
    id: "multi-turn-refinement",
    mockIntent: "25",
    prompts: {
      en: ["Suggest a simple weekend learning plan for Swift.", "Make it suitable for a beginner with only two hours."],
      "zh-Hans": ["请建议一个周末学习 Swift 的简单计划。", "把它调整为适合只有两小时的初学者。"],
      mixed: ["请建议一个 weekend Swift learning plan。", "Make it suitable for 只有两小时的初学者。"],
    },
    success: "The follow-up preserves context and visibly refines the first answer",
    responseShape: "multiTurnText",
  },
  {
    id: "read-only-app-inspection",
    mockIntent: "80",
    prompts: {
      en: ["Tell me which model and appearance this chat is using. Do not change anything."],
      "zh-Hans": ["告诉我这个聊天正在使用哪个模型和外观设置，不要更改任何内容。"],
      mixed: ["告诉我这个 chat 使用的 model 和 appearance，不要修改。"],
    },
    success: "Ox inspects its current state without changing it or requesting unnecessary access",
    responseShape: "readOnlyToolResult",
  },
  {
    id: "formatted-explanation",
    mockIntent: "18",
    prompts: {
      en: ["Explain a binary search with a short example and a small Swift code block."],
      "zh-Hans": ["请用一个简短示例和一小段 Swift 代码解释二分查找。"],
      mixed: ["请解释 binary search，并给一个简短示例和 Swift code block。"],
    },
    success: "Formatted text and code remain readable during and after streaming",
    responseShape: "codeAndText",
  },
  {
    id: "ambiguity-and-choice",
    mockIntent: "24",
    prompts: {
      en: ["Help me clean up my old chats, but do not delete anything without asking me first."],
      "zh-Hans": ["帮我整理旧聊天，但未经询问不要删除任何内容。"],
      mixed: ["帮我 clean up old chats，但没有先询问不要删除。"],
    },
    success: "Ox handles ambiguity and preserves user control without unauthorized mutation",
    responseShape: "interactiveChoice",
  },
  {
    id: "recovery",
    mockIntent: "53",
    prompts: {
      en: ["Try a safe read-only approach, and recover clearly if a tool is unavailable."],
      "zh-Hans": ["请尝试安全的只读方法，如果工具不可用，请清楚地恢复。"],
      mixed: ["请尝试 safe read-only approach，工具不可用时清楚恢复。"],
    },
    success: "A failure is explained and the session recovers or terminates coherently",
    responseShape: "recovery",
  },
];

const stressIntents: Intent[] = [
  {
    id: "slow-first-token",
    mockIntent: "2",
    prompts: intents[1]!.prompts,
    success: "The waiting experience remains understandable and responsive",
    responseShape: "slowFirstToken",
    mockOnly: true,
  },
  {
    id: "midstream-error",
    mockIntent: "4",
    prompts: intents[6]!.prompts,
    success: "A midstream failure produces a clear recoverable terminal state",
    responseShape: "midstreamError",
    mockOnly: true,
  },
  {
    id: "rate-limit",
    mockIntent: "71",
    prompts: intents[6]!.prompts,
    success: "Rate limiting is presented clearly without loops or lost input",
    responseShape: "rateLimitError",
    mockOnly: true,
  },
  {
    id: "long-output",
    mockIntent: "1",
    prompts: {
      en: ["Write a detailed 700-word guide to planning a community picnic with headings, lists, and a short checklist."],
      "zh-Hans": ["请写一篇约 700 字的社区野餐策划指南，包含标题、列表和简短检查清单。"],
      mixed: ["请写一篇 detailed community picnic guide，包含 headings、lists 和 checklist。"],
    },
    success: "Long streaming output remains responsive and navigable",
    responseShape: "longStructuredText",
  },
  {
    id: "background-stream",
    mockIntent: "19",
    prompts: {
      en: ["Develop a detailed weekend Swift learning plan with explanations for each activity."],
      "zh-Hans": ["请制定一个详细的周末 Swift 学习计划，并解释每项活动。"],
      mixed: ["请制定 detailed weekend Swift learning plan，并解释每项 activity。"],
    },
    success: "Backgrounding and returning preserves a coherent active or completed response",
    responseShape: "backgroundStreamingText",
  },
  {
    id: "cjk-emoji-table",
    mockIntent: "11",
    prompts: {
      en: ["Create a Chinese comparison table with emoji and one short Swift code example."],
      "zh-Hans": ["请创建一个包含表情符号的中文比较表，并附上一小段 Swift 代码示例。"],
      mixed: ["请创建 Chinese comparison table，包含 emoji 和 Swift code example。"],
    },
    success: "CJK, emoji, and table content remain readable without clipping",
    responseShape: "cjkEmojiTable",
  },
];

const dimensions = {
  fluency: ["novice", "familiar", "expert"],
  patience: ["low", "medium", "high"],
  trust: ["cautious", "balanced", "eager"],
  exploration: ["shallow", "moderate", "deep"],
  verbosity: ["concise", "balanced", "detailed"],
  theme: ["creatorPick", "light", "dark"],
  promptLanguage: ["en", "zh-Hans", "mixed"],
  inputMethod: ["type", "paste"],
  accessibility: ["default", "largeText", "reducedMotion", "increasedContrast"],
  keyboard: ["hardwareConnected", "software"],
  conversation: ["new", "multiTurn", "restored", "modelSwitched"],
  lifecycle: ["foreground", "backgroundReturn", "cancelAndRetry", "relaunch"],
} as const;

const reservedDimensions = new Set([
  "theme",
  "appLanguage",
  "promptLanguage",
  "responseShape",
  "inputMethod",
  "accessibility",
  "keyboard",
  "conversation",
  "lifecycle",
  "providerCondition",
]);

function usage(): string {
  return `Usage: bun .agents/skills/ox-gym/scripts/plan-run.ts [options]

Options:
  --mode <explore|compare|stress>  Campaign mode (default explore)
  --sessions <n>                  Total user sessions (default 6)
  --seed <value>                  Reproducible campaign seed
  --target <client:model>         Ox provider target; repeat as needed
  --device <ox-qa-N>              Numbered QA simulator; repeat as needed
  --app-language <locale>         Discovered Ox UI locale; repeat as needed
  --dimension <key=v1,v2>         Eligible additional axis; repeat as needed
  --authorize-real                Record authorization for bounded real-provider calls
  --max-provider-calls <n>        Calls per session, including retries (default 3)
  --previous <campaign.json>      Explicit prior ephemeral coverage input; repeat as needed`;
}

function valueAfter(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function modeValue(value: string): Mode {
  if (value === "explore" || value === "compare" || value === "stress") return value;
  throw new Error(`unknown mode ${value}`);
}

function positiveInteger(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${flag} must be a positive integer`);
  return parsed;
}

function addDimension(options: Options, specification: string): void {
  const separator = specification.indexOf("=");
  if (separator < 1) throw new Error("--dimension requires key=value1,value2");
  const key = specification.slice(0, separator);
  const values = specification.slice(separator + 1).split(",").filter(Boolean);
  if (!/^[A-Za-z][A-Za-z0-9.-]*$/.test(key) || values.length === 0) throw new Error(`invalid dimension ${specification}`);
  if (reservedDimensions.has(key)) throw new Error(`dimension ${key} is built in and cannot be overridden`);
  options.extraDimensions[key] = [...new Set(values)];
}

function finalized(options: Options): Options {
  options.targets = options.targets.length > 0 ? [...new Set(options.targets)] : ["mock:mock"];
  options.devices = options.devices.length > 0 ? [...new Set(options.devices)] : ["ox-qa-1", "ox-qa-2", "ox-qa-3"];
  options.appLanguages = options.appLanguages.length > 0 ? [...new Set(options.appLanguages)] : ["en", "zh-Hans"];
  for (const device of options.devices) {
    if (!/^ox-qa-[1-5]$/.test(device)) throw new Error(`invalid numbered QA simulator ${device}`);
  }
  if (options.mode === "compare" && options.targets.length < 2) throw new Error("compare mode requires at least two --target values");
  if (options.mode === "compare" && options.sessions % options.targets.length !== 0) {
    throw new Error("compare mode session count must be divisible by the number of targets");
  }
  return options;
}

function parse(args: string[]): Options | undefined {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(usage());
    return undefined;
  }
  const options: Options = {
    mode: "explore",
    sessions: 6,
    seed: `${Date.now()}-${randomUUID()}`,
    targets: [],
    devices: [],
    appLanguages: [],
    extraDimensions: {},
    authorizeReal: false,
    maximumProviderCalls: 3,
    previous: [],
  };
  const handlers: Record<string, (value: string) => void> = {
    "--mode": value => { options.mode = modeValue(value); },
    "--sessions": value => { options.sessions = positiveInteger(value, "--sessions"); },
    "--seed": value => { options.seed = value; },
    "--target": value => { options.targets.push(value); },
    "--device": value => { options.devices.push(value); },
    "--app-language": value => { options.appLanguages.push(value); },
    "--dimension": value => { addDimension(options, value); },
    "--max-provider-calls": value => { options.maximumProviderCalls = positiveInteger(value, "--max-provider-calls"); },
    "--previous": value => { options.previous.push(value); },
  };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index]!;
    if (argument === "--authorize-real") {
      options.authorizeReal = true;
      continue;
    }
    const handler = handlers[argument];
    if (!handler) throw new Error(`unknown option ${argument}`);
    handler(valueAfter(args, index++, argument));
  }
  return finalized(options);
}

function hash(value: string): number {
  let result = 2166136261;
  for (const character of value) {
    result ^= character.codePointAt(0)!;
    result = Math.imul(result, 16777619);
  }
  return result >>> 0;
}

function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function pick<T>(values: readonly T[], rng: () => number): T {
  return values[Math.floor(rng() * values.length)]!;
}

function isMock(target: string): boolean {
  return target.split(":", 1)[0]?.toLowerCase() === "mock";
}

function additionalEnvironment(extraDimensions: Record<string, string[]>, rng?: () => number): Record<string, string> {
  return Object.fromEntries(Object.entries(extraDimensions).map(([key, values]) => [key, rng ? pick(values, rng) : values[0]!]));
}

function assignment(
  rng: () => number,
  mode: Mode,
  appLanguages: string[],
  extraDimensions: Record<string, string[]>,
  target?: string,
): Assignment {
  const eligibleStress = target && !isMock(target) ? stressIntents.filter(intent => !intent.mockOnly) : stressIntents;
  const pool = mode === "stress" ? [...intents, ...eligibleStress, ...eligibleStress] : intents;
  const conversation = pick(dimensions.conversation, rng);
  const multiTurn = new Set(["multi-turn-refinement", "read-only-app-inspection", "ambiguity-and-choice", "recovery"]);
  const intentPool = conversation === "multiTurn" ? pool.filter(intent => multiTurn.has(intent.id)) : pool;
  const intent = pick(intentPool, rng);
  return {
    persona: {
      fluency: pick(dimensions.fluency, rng),
      patience: pick(dimensions.patience, rng),
      trust: pick(dimensions.trust, rng),
      exploration: pick(dimensions.exploration, rng),
      verbosity: pick(dimensions.verbosity, rng),
    },
    intent,
    environment: {
      theme: pick(dimensions.theme, rng),
      appLanguage: pick(appLanguages, rng),
      promptLanguage: pick(dimensions.promptLanguage, rng),
      responseShape: intent.responseShape,
      inputMethod: pick(dimensions.inputMethod, rng),
      accessibility: pick(dimensions.accessibility, rng),
      keyboard: pick(dimensions.keyboard, rng),
      conversation,
      lifecycle: pick(dimensions.lifecycle, rng),
      ...additionalEnvironment(extraDimensions, rng),
    },
  };
}

function coreAssignment(extraDimensions: Record<string, string[]>): Assignment {
  return {
    persona: { fluency: "familiar", patience: "medium", trust: "balanced", exploration: "moderate", verbosity: "balanced" },
    intent: intents[0]!,
    environment: {
      theme: "creatorPick",
      appLanguage: "en",
      promptLanguage: "en",
      responseShape: intents[0]!.responseShape,
      inputMethod: "type",
      accessibility: "default",
      keyboard: "hardwareConnected",
      conversation: "new",
      lifecycle: "foreground",
      ...additionalEnvironment(extraDimensions),
    },
  };
}

function flattened(value: Assignment, providerTarget?: string): string[] {
  return [
    ...Object.entries(value.persona).map(([key, item]) => `persona.${key}=${item}`),
    `intent=${value.intent.id}`,
    ...Object.entries(value.environment).map(([key, item]) => `environment.${key}=${item}`),
    ...(providerTarget ? [`provider=${providerTarget}`] : []),
  ].sort();
}

function pairs(values: string[]): string[] {
  const output: string[] = [];
  for (let left = 0; left < values.length; left += 1) {
    for (let right = left + 1; right < values.length; right += 1) output.push(`${values[left]}|${values[right]}`);
  }
  return output;
}

function recordCoverage(value: Assignment, providerTarget: string | undefined, seenValues: Set<string>, seenPairs: Set<string>): void {
  const values = flattened(value, providerTarget);
  for (const item of values) seenValues.add(item);
  for (const item of pairs(values)) seenPairs.add(item);
}

function score(value: Assignment, providerTarget: string | undefined, seenValues: Set<string>, seenPairs: Set<string>): number {
  const values = flattened(value, providerTarget);
  const newValues = values.filter(item => !seenValues.has(item)).length;
  const newPairs = pairs(values).filter(item => !seenPairs.has(item)).length;
  return newValues * 20 + newPairs;
}

function choose(
  rng: () => number,
  mode: Mode,
  appLanguages: string[],
  extraDimensions: Record<string, string[]>,
  providerTarget: string | undefined,
  seenValues: Set<string>,
  seenPairs: Set<string>,
): Assignment {
  let selected = assignment(rng, mode, appLanguages, extraDimensions, providerTarget);
  let selectedScore = score(selected, providerTarget, seenValues, seenPairs);
  for (let index = 0; index < 127; index += 1) {
    const candidate = assignment(rng, mode, appLanguages, extraDimensions, providerTarget);
    const candidateScore = score(candidate, providerTarget, seenValues, seenPairs);
    if (candidateScore > selectedScore || (candidateScore === selectedScore && rng() > 0.5)) {
      selected = candidate;
      selectedScore = candidateScore;
    }
  }
  return selected;
}

function promptsFor(value: Assignment, target: string): string[] {
  if (isMock(target)) return [value.intent.mockIntent];
  const language = value.environment.promptLanguage as "en" | "zh-Hans" | "mixed";
  const prompts = [...value.intent.prompts[language]];
  if (value.environment.conversation === "multiTurn" && prompts.length === 1) {
    prompts.push({
      en: "Now refine that answer to be shorter and account for one important constraint.",
      "zh-Hans": "现在请把答案精简一些，并考虑一个重要限制条件。",
      mixed: "现在请 refine the answer，让它更短并考虑一个 important constraint。",
    }[language]);
  }
  return prompts;
}

function environmentFor(value: Assignment, target: string): Record<string, string> {
  if (!isMock(target)) return { ...value.environment, providerCondition: "natural" };
  const providerCondition = value.intent.mockOnly ? value.intent.id : "scenarioControlled";
  return {
    ...value.environment,
    promptLanguage: "control",
    inputMethod: value.environment.inputMethod === "paste" ? "paste" : "type",
    providerCondition,
  };
}

async function priorCoverage(paths: string[], seenValues: Set<string>, seenPairs: Set<string>): Promise<void> {
  for (const path of paths) {
    const document = JSON.parse(await readFile(path, "utf8")) as { sessions?: Array<PlannedSession> };
    for (const session of document.sessions ?? []) {
      const value: Assignment = {
        persona: session.persona,
        intent: {
          id: session.intent.id,
          success: session.intent.success,
          mockIntent: "",
          prompts: { en: [], "zh-Hans": [], mixed: [] },
          responseShape: session.environment.responseShape ?? "unknown",
        },
        environment: session.environment,
      };
      recordCoverage(value, session.providerTarget, seenValues, seenPairs);
    }
  }
}

async function main(): Promise<void> {
  const options = parse(Bun.argv.slice(2));
  if (!options) return;
  const rng = random(hash(options.seed));
  const seenValues = new Set<string>();
  const seenPairs = new Set<string>();
  const plannedValues = new Set<string>();
  const plannedPairs = new Set<string>();
  await priorCoverage(options.previous, seenValues, seenPairs);
  const directory = await mkdtemp("/tmp/ox-gym.");
  const sessionRoot = `${directory}/sessions`;
  await mkdir(sessionRoot);
  const sessions: PlannedSession[] = [];
  const targetCount = options.targets.length;
  let sharedAssignment: Assignment | undefined;
  for (let index = 0; index < options.sessions; index += 1) {
    const id = `session-${String(index + 1).padStart(3, "0")}`;
    const providerTarget = options.targets[index % targetCount]!;
    const comparisonGroup = options.mode === "compare" ? Math.floor(index / targetCount) : undefined;
    const targetIndex = index % targetCount;
    if (options.mode === "compare") {
      if (index % targetCount === 0) {
        sharedAssignment = comparisonGroup === 0
          ? coreAssignment(options.extraDimensions)
          : choose(rng, options.mode, options.appLanguages, options.extraDimensions, undefined, seenValues, seenPairs);
      }
    } else {
      sharedAssignment = index === 0
        ? coreAssignment(options.extraDimensions)
        : choose(rng, options.mode, options.appLanguages, options.extraDimensions, providerTarget, seenValues, seenPairs);
    }
    const selected = sharedAssignment!;
    const environment = environmentFor(selected, providerTarget);
    const materialized = { ...selected, environment };
    recordCoverage(materialized, providerTarget, seenValues, seenPairs);
    recordCoverage(materialized, providerTarget, plannedValues, plannedPairs);
    const evidenceDirectory = `${sessionRoot}/${id}`;
    await mkdir(`${evidenceDirectory}/screenshots`, { recursive: true });
    const simulatorIndex = comparisonGroup === undefined ? index : comparisonGroup + targetIndex;
    const realProvider = !isMock(providerTarget);
    sessions.push({
      id,
      ...(comparisonGroup === undefined ? {} : { pairID: `pair-${String(comparisonGroup + 1).padStart(3, "0")}` }),
      wave: Math.floor(index / options.devices.length) + 1,
      seed: hash(`${options.seed}:${comparisonGroup === undefined ? index : `pair:${comparisonGroup}`}`),
      simulator: options.devices[simulatorIndex % options.devices.length]!,
      providerTarget,
      persona: selected.persona,
      intent: { id: selected.intent.id, success: selected.intent.success },
      prompts: promptsFor(selected, providerTarget),
      environment,
      budgets: {
        wallClockSeconds: 120,
        explorationCutoffSeconds: 90,
        completionCutoffSeconds: 105,
        maximumSteps: 20,
        maximumRetries: 1,
        maximumProviderCalls: options.maximumProviderCalls,
      },
      materializationStatus: "required",
      providerVerification: "required",
      providerCallsAuthorized: !realProvider || options.authorizeReal,
      executionAuthorized: false,
      setup: [],
      plannedActions: [],
      allowedEffects: {
        modelProviderCalls: !realProvider || options.authorizeReal,
        realProviderCalls: realProvider && options.authorizeReal,
        externalMutation: false,
        credentialAccess: false,
      },
      evidenceDirectory,
    });
  }
  const campaign = {
    version: 1,
    kind: "ox-gym-campaign",
    generatedAt: new Date().toISOString(),
    seed: options.seed,
    mode: options.mode,
    stateless: true,
    outputDirectory: directory,
    previousCoverageInputs: options.previous,
    targets: options.targets,
    devices: options.devices,
    appLanguages: options.appLanguages,
    extraDimensions: options.extraDimensions,
    realProviderAuthorized: options.authorizeReal,
    maximumProviderCallsPerSession: options.maximumProviderCalls,
    comparisonPairCount: options.mode === "compare" ? options.sessions / options.targets.length : 0,
    sessions,
    coverage: {
      plannedValues: [...plannedValues].sort(),
      plannedPairCount: plannedPairs.size,
    },
  };
  const manifest = `${directory}/campaign.json`;
  await writeFile(manifest, `${JSON.stringify(campaign, null, 2)}\n`);
  console.log(JSON.stringify({ directory, manifest, seed: options.seed, sessionCount: sessions.length }));
}

try {
  await main();
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
