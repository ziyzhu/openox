import { renderToolSignature } from "@earendil-works/pi-codemode/declarations";
import fsContracts from "../functions/fs/contracts.json";
import serviceContracts from "../functions/service/contracts.json";
import webContracts from "../functions/web/contracts.json";
import { standardServiceActions } from "../functions/service/standard-actions";

const fetchOutput = webContracts["ox.web.fetch"].outputSchema;
const { additionalProperties: feedValue, ...feedFields } = fetchOutput.properties.feed;

const commonContracts = {
  "ox.fs.read": fsContracts["ox.fs.read"],
  "ox.fs.edit": fsContracts["ox.fs.edit"],
  "ox.fs.write": fsContracts["ox.fs.write"],
  "ox.web.search": webContracts["ox.web.search"],
  "ox.web.fetch": {
    ...webContracts["ox.web.fetch"],
    outputSchema: {
      ...fetchOutput,
      properties: {
        ...fetchOutput.properties,
        feed: { allOf: [feedFields, { type: "object", additionalProperties: feedValue }] },
      },
    },
  },
  "ox.service.attach": serviceContracts["ox.service.attach"],
  "ox.service.inspect": serviceContracts["ox.service.inspect"],
  "ox.service.invoke": serviceContracts["ox.service.invoke"],
};

const commonDeclarations = ["fs", "web", "service"].map(namespace => {
  const functions = Object.entries(commonContracts).filter(([name]) => name.startsWith(`ox.${namespace}.`))
    .map(([name, contract]) => {
      const description = contract.description.replace(/: `await [^`]+`/g, "").replace(/`await [^`]+`/g, "").replace(/`(ox\.[\w.]+)\([^`]*\)`/g, "`$1`").replaceAll("*/", "*\\/");
      const signature = renderToolSignature({ ...contract, name: name.split(".").at(-1)! });
      return `  /** ${description} */\n  function ${signature}`;
    }).join("\n");
  return `declare namespace ox.${namespace} {\n${functions}\n}`;
}).join("\n\n");

const standardActionDeclarations = Object.entries(standardServiceActions).map(([kind, actions]) =>
  `type ${kind}StandardActions = {\n` + actions.map(action => `  /** ${action.description} */\n  ${renderToolSignature({ ...action, name: action.id })}`).join("\n") + "\n};"
).join("\n\n");

export const countWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const countWord = (value: number) => countWords[value] ?? String(value);
export interface ExecuteGuidanceInput {
  catalog: string; timeoutSeconds: number; maxLines: number; maxBytes: number;
  maxFetches?: number; maxTransientAttachments?: number; canCancelLoops?: boolean;
}

export function executeGuidance(input: ExecuteGuidanceInput) {
  if (typeof input?.catalog !== "string" || ![input.timeoutSeconds, input.maxLines, input.maxBytes].every(value => Number.isSafeInteger(value) && value > 0)
    || ![input.maxFetches ?? 8, input.maxTransientAttachments ?? 4].every(value => Number.isSafeInteger(value) && value >= 0)) throw new Error("Invalid execution guidance facts");
  return [
    "Run JavaScript as an async function body. Top-level await and return work. Print model-visible results with console.log or return. Use only exposed capabilities; no shell, Node, or direct filesystem access.",
    input.catalog,
    "The catalog contains summaries, not full contracts. Use the declarations below immediately; executions are JavaScript, not TypeScript. Before using other unfamiliar functions, print their synchronous .help(), batching needed contracts with independent work in the same execution. Reuse contracts already supplied here or by ox.service.inspect. Operational calls require a short purpose; help and ox.provider.schema() do not. Use ox.fs for files.",
    "Common built-in functions:\n```ts\n" + commonDeclarations + "\n```",
    "Call standard service actions through ox.service.invoke, not as ox methods. Their full contracts follow; no further schema discovery is needed. Establish optional website action availability from inspection's standardActions or existing evidence. Other service types always expose their two standard actions, including before MCP discovery succeeds. Inspect paginates non-standard contracts. Do not assume optional support, preflight every action, or replay writes after setup.",
    "Standard action contracts:\n```ts\n" + standardActionDeclarations + "\n```",
    "Use service handoffs for login, review, human verification, and payment. Never request credentials in chat, submit payment from preparation, or replay writes after handoff.",
    `Batch independent reads with Promise.allSettled and chain predictable dependent steps, stopping on failure. Filter large results before printing; return to the model only when evidence requires a decision. Serialize writes and approval-dependent calls. Await needed calls; pending calls are cancelled at script exit. Effects are not rolled back on failure. Preserve error code, message, and recovery with console.error(error) or return; verify uncertain effects before retrying writes.`,
    `Each execution is self-contained; never store continuation state on globalThis. Return concise progress or persist it through an authorized file. Use bounded loops. The active execution limit is ${input.timeoutSeconds} seconds. ${input.canCancelLoops ? "The runtime supports interrupting JavaScript loops." : "Cancellation does not forcibly stop an infinite JavaScript loop."}`,
    `Service actions and user handoffs do not consume active execution time. Each execution may fetch at most ${countWord(input.maxFetches ?? 8)} public resources and add at most ${countWord(input.maxTransientAttachments ?? 4)} transient attachments; presented files do not count toward that attachment limit.`,
    `Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first. A clipped preview is incomplete. Full output is saved in a read-only conversation-local /tmp file until the conversation unloads; inspect it with ox.fs.read or ox.fs.grep. File pagination is a separate limit.`,
  ].join("\n\n");
}
