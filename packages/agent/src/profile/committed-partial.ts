import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { AgentEvent } from "@earendil-works/pi-durable";

/** Apply committed view operations to a detached presentation value, never mutate a published frame. */
export function applyChanges(message: AssistantMessage, event: Extract<AgentEvent, { type: "message_update" }>) {
  message.usage = event.usage;
  for (const change of event.changes) {
    if (change.type === "message") Object.assign(message, structuredClone(change.message));
    else if (change.type === "block" || change.type.endsWith("_start")) {
      if ("block" in change) message.content[change.contentIndex] = structuredClone(change.block);
    } else if (change.type === "text_delta" || change.type === "thinking_delta") {
      const block = message.content[change.contentIndex];
      if (block?.type === "text" && change.type === "text_delta") block.text += change.delta;
      if (block?.type === "thinking" && change.type === "thinking_delta") block.thinking += change.delta;
    } else if (change.type === "toolcall_delta") {
      const block = message.content[change.contentIndex];
      if (block?.type !== "toolCall") throw new Error("Committed tool delta has no tool call");
      let object: Record<string | number, unknown> = block.arguments;
      for (const key of change.path.slice(0, -1)) object = object[key] as typeof object;
      const key = change.path.at(-1)!;
      object[key] = String(object[key] ?? "") + change.delta;
    }
  }
}
