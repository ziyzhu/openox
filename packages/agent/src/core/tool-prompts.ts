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
  "ox.web.browser.newPage": webContracts["ox.web.browser.newPage"],
  "ox.web.browser.frames": webContracts["ox.web.browser.frames"],
  "ox.web.browser.goto": webContracts["ox.web.browser.goto"],
  "ox.web.browser.evaluate": webContracts["ox.web.browser.evaluate"],
  "ox.web.browser.snapshot": webContracts["ox.web.browser.snapshot"],
  "ox.web.browser.showPage": webContracts["ox.web.browser.showPage"],
  "ox.web.browser.close": webContracts["ox.web.browser.close"],
  "ox.service.inspect": serviceContracts["ox.service.inspect"],
  "ox.service.invoke": serviceContracts["ox.service.invoke"],
};

const commonDeclarations = ["fs", "web", "web.browser", "service"].map(namespace => {
  const functions = Object.entries(commonContracts).filter(([name]) => name.slice(0, name.lastIndexOf(".")) === `ox.${namespace}`)
    .map(([name, contract]) => {
      const description = contract.description.replace(/: `await [^`]+`/g, "").replace(/`await (ox\.[\w.]+)\([^`]*\)`/g, "`$1`").replace(/`(ox\.[\w.]+)\([^`]*\)`/g, "`$1`").replaceAll("*/", "*\\/");
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
    "Run JavaScript as an async function body. Top-level await and return work. Emit text with console.log or return. Use await image(block) to send a Base64 image block from ox.fs.read or an image data URL to the model, not the conversation UI; it does not save a file or fetch remote URLs. Images share the transient attachment limits. Do not print Base64. Use only exposed capabilities; no shell, Node, or direct filesystem access.",
    input.catalog,
    "The catalog contains summaries, not full contracts. Use the declarations below immediately; executions are JavaScript, not TypeScript. Find functions by task with await searchTools(query, { limit?, namespace? }); it returns up to eight ranked { name, description } summaries by default and does not invoke or attach anything. Before calling an unfamiliar match, print its full contract with its synchronous .help() (for example, ox.fs.grep.help()). Batch needed contracts with independent work in the same execution. Reuse contracts already supplied here or by ox.service.inspect. Operational calls require a short purpose; help and ox.provider.schema() do not. Use ox.fs for files.",
    "Common built-in functions:\n```ts\n" + commonDeclarations + "\n```",
    "Call standard service actions through ox.service.invoke, not as ox methods. Their full contracts follow; no further schema discovery is needed. Establish optional website action availability from inspect standardActions or existing evidence. Other service types always expose their two standard actions, including before MCP discovery succeeds. Inspect returns paginated non-standard contracts. Invocation automatically attaches its service when needed, including standard setup actions, under normal attachment policy. Inspection does not attach services. Attachment does not grant permissions or authentication. Do not assume optional support, preflight every action, or replay writes after setup.",
    "Standard action contracts:\n```ts\n" + standardActionDeclarations + "\n```",
    "Read skills/authentication/SKILL.md for website authentication and account creation, and skills/checkout/SKILL.md for transaction review and payment. Other human-verification handoffs follow Evolve's web-handoffs reference. For an observed human-verification challenge, present the exact live page with ox.web.browser.showPage even if it appears blank or usable controls cannot be verified; explain the blocker and disclose the display uncertainty. Also present the exact page when the user asks to see it. After showPage returns completed, immediately discover fresh frames on the same pageId and inspect the current document before replying or ending the turn; replace the pre-handoff blocker assessment with fresh evidence and continue the original task when unblocked. Do not require another user message to resume. Never bypass human-verification challenges or request their answers or tokens.",
    `Batch independent reads with Promise.allSettled and chain predictable dependent steps, stopping on failure. Filter large results before printing; return to the model only when evidence requires a decision. Serialize writes and approval-dependent calls. Await needed calls; pending calls are cancelled at script exit. Effects are not rolled back on failure. Preserve error code, message, and recovery with console.error(error) or return; verify uncertain effects before retrying writes.`,
    `Each execution is self-contained; never store continuation state on globalThis. Return concise progress or persist it through an authorized file. Use bounded loops. The active execution limit is ${input.timeoutSeconds} seconds. ${input.canCancelLoops ? "The runtime supports interrupting JavaScript loops." : "Cancellation does not forcibly stop an infinite JavaScript loop."}`,
    `Service actions and user handoffs do not consume active execution time. Each execution may fetch at most ${countWord(input.maxFetches ?? 8)} public resources and add at most ${countWord(input.maxTransientAttachments ?? 4)} transient attachments; presented files do not count toward that attachment limit.`,
    `Combined console and return output is limited to the last ${input.maxLines} lines or ${Math.floor(input.maxBytes / 1024)} KiB, whichever is reached first. A clipped preview is incomplete. Full output is saved in a read-only conversation-local /tmp file until the conversation unloads; inspect it with ox.fs.read or ox.fs.grep. File pagination is a separate limit.`,
  ].join("\n\n");
}
