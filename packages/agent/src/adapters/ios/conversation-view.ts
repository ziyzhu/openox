import type { AssistantMessage, ToolCall } from "@earendil-works/pi-ai";
import type { Conversation, EntryId, EntryRecord, LiveState } from "@earendil-works/pi-durable";
import type { ConversationUpdate } from "../../profile/runtime";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";

export function conversationEvents(conversation: Conversation) {
  let newest: number | undefined;
  let generation: number | undefined;
  let assistant: EntryRecord | undefined;
  let partial: AssistantMessage | undefined;
  let running = false;
  const started = new Set<string>();
  const ended = new Set<string>();
  return async ({ value: view, ops }: ConversationUpdate) => {
    const events: Record<string, unknown>[] = [];
    const live = view.docs["pi.live"] as LiveState | undefined;
    const begin = (id: number) => {
      if (generation !== undefined) return;
      generation = id;
      assistant = undefined;
      partial = undefined;
      started.clear(); ended.clear();
      events.push({ type: "turn_start" });
    };
    const finish = () => {
      if (generation === undefined) return;
      events.push({ type: "turn_end" });
      generation = undefined;
      assistant = undefined;
      partial = undefined;
    };
    const calls = () => assistant?.model?.flatMap(message => message.role === "assistant"
      ? message.content.filter((block): block is ToolCall => block.type === "toolCall") : []) ?? [];
    const startTool = (id: string, name?: string) => {
      if (started.has(id)) return;
      const call = calls().find(call => call.id === id);
      events.push({ type: "tool_execution_start", toolCallId: id, toolName: call?.name ?? name, args: call?.arguments ?? {} });
      started.add(id);
    };
    const initial = newest === undefined;
    if (initial) newest = view.entries.at(-1)?.id ?? view.before ?? 0;
    let entries: readonly EntryRecord[] = view.entries;
    if (!initial && view.before !== undefined && view.before > newest!) {
      const recovered: EntryRecord[] = [];
      let cursor;
      do {
        const page = await conversation.entries({ minEntryId: (newest! + 1) as EntryId, maxEntryId: view.before, order: "ascending" }, 100, cursor, BACKGROUND_CONTEXT);
        recovered.push(...page.items);
        cursor = page.next;
      } while (cursor);
      entries = [...recovered, ...entries];
    }
    const fresh = entries.filter(entry => entry.id > newest!);
    if (!running && (live?.run || fresh.some(entry => entry.model?.some(message => message.role === "assistant")))) {
      events.push({ type: "run_start" });
      running = true;
    }
    for (const entry of fresh) {
      for (const message of entry.model ?? []) {
        if (message.role === "assistant") {
          if (assistant) finish();
          begin(entry.byTaskId ?? entry.id);
          if (!partial) events.push({ type: "message_start", message });
          events.push({ type: "message_end", entry: { ...entry, model: [message] } });
          assistant = entry;
          partial = undefined;
        } else if (message.role === "toolResult") {
          startTool(message.toolCallId, message.toolName);
          events.push({ type: "tool_execution_end", toolCallId: message.toolCallId, entry: { ...entry, model: [message] } });
          ended.add(message.toolCallId);
        } else if (message.role === "user") {
          events.push({ type: "message_start", message }, { type: "message_end", entry: { ...entry, model: [message] } });
        }
      }
      newest = entry.id;
    }
    for (const tool of live?.tools ?? []) {
      if (tool.status !== "pending") startTool(tool.callId, tool.name);
    }
    if (live?.generation && live.run) {
      if (assistant) finish();
      begin(live.run.taskId);
      const message = live.generation.message as AssistantMessage | undefined;
      if (message && message !== partial) {
        if (!partial) events.push({ type: "message_start", message });
        else {
          const changes: { type: string; contentIndex: number; delta: string }[] = [];
          let replace = false;
          for (const op of ops) {
            if (op[0] === "r") { replace = true; break; }
            const path = op[1];
            if (path[0] !== "docs" || path[1] !== "pi.live") continue;
            if (path.length < 4) { replace = true; break; }
            if (path[2] !== "generation" || path[3] !== "message") continue;
            if (path[4] === "usage") continue;
            if (op[0] === "a" && path.length === 7 && path[4] === "content" && typeof path[5] === "number"
              && (path[6] === "text" || path[6] === "thinking")) {
              changes.push({ type: path[6] === "text" ? "text_delta" : "thinking_delta", contentIndex: path[5], delta: op[2] });
            } else replace = true;
          }
          if (replace || !changes.length) events.push({ type: "message_update", partial: message });
          else events.push({ type: "message_update", changes });
        }
        partial = message;
      }
    }
    if (!live?.run) {
      finish();
      running = false;
    } else if (assistant && calls().every(call => ended.has(call.id)) && !live.tools?.length) finish();
    return events;
  };
}
