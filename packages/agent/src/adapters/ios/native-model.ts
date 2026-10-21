import type { Api, AssistantMessage, AssistantMessageEvent, Message, Model, SimpleStreamOptions, TranscriptContext } from "@earendil-works/pi-ai";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { getCurrentTools, getInitialSystemMessage, resolveTranscript, withoutInitialSystemMessage } from "@earendil-works/pi-ai/utils/transcript";
import { getSystemMessageText, renderSystemMessageUpdate } from "@earendil-works/pi-ai";
import { native } from "./bridge";
import type { ConversationReference } from "../../profile/conversations";

export const emptyUsage = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });

function nativeTranscript(transcript: TranscriptContext, systemUpdates: boolean) {
  const { messages } = resolveTranscript(transcript, systemUpdates);
  const initial = getInitialSystemMessage(messages);
  const ordered: (Message | { role: "system"; text: string; timestamp: number })[] = [];
  for (const message of withoutInitialSystemMessage(messages)) {
    if (message.role !== "system") { ordered.push(message); continue; }
    let index = ordered.length;
    while (index > 0 && ordered[index - 1]!.role === "user") index--;
    ordered.splice(index, 0, { role: "system", text: renderSystemMessageUpdate(message), timestamp: message.timestamp });
  }
  return { systemPrompt: initial ? getSystemMessageText(initial) : "", messages: ordered };
}

export function nativeStream(reference: ConversationReference, model: Model<Api>, transcript: TranscriptContext, systemUpdates: boolean, options?: SimpleStreamOptions) {
  const output = createAssistantMessageEventStream();
  let terminal = false;
  let partial: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
    content: [], usage: emptyUsage(), stopReason: "pending", timestamp: Date.now() };
  void (async () => {
    try {
      if (options?.deferred) throw new Error("Native deferred generation is unsupported");
      const tools = getCurrentTools(transcript.messages);
      const purpose = options?.cacheRetention === "none" && tools.length === 0 ? "compaction" : "generation";
      await native("nativeModel", { conversationID: reference.conversationID, reference, purpose, streamOptions: { maxTokens: options?.maxTokens, cacheRetention: options?.cacheRetention },
        tools, ...nativeTranscript(transcript, systemUpdates) },
      options?.signal, value => {
        const event = value as AssistantMessageEvent;
        if (terminal) {
          void native("report", { message: "Native provider emitted after its terminal event; ignored" }).catch(() => {});
          return;
        }
        if ("partial" in event) { partial = event.partial; partial.api = model.api; partial.provider = model.provider; }
        if (event.type === "done" || event.type === "error") {
          const allowed = event.type === "done" ? ["stop", "length", "toolUse"] : ["error", "aborted"];
          if (!allowed.includes(event.reason)) throw new Error(`Invalid native terminal reason: ${event.reason}`);
          terminal = true;
          const message = event.type === "done" ? event.message : event.error;
          message.api = model.api; message.provider = model.provider; message.stopReason = event.reason;
        }
        output.push(event);
      });
      if (!terminal) throw new Error("Native provider stream ended without a terminal event");
    } catch (error) {
      if (terminal) return;
      const reason = options?.signal?.aborted ? "aborted" : "error";
      output.push({ type: "error", reason, error: { ...partial, stopReason: reason, errorMessage: String(error) } });
    }
  })();
  return output;
}
