import type { Api, AssistantMessage, AssistantMessageEvent, Model, SimpleStreamOptions, TranscriptContext } from "@earendil-works/pi-ai";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import { native } from "./bridge";

export const emptyUsage = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });

/** Swift's contract has a leading prompt/tools, not positional system messages. Use Pi's specified collapse semantics. */
export function nativeStream(chatID: string, model: Model<Api>, transcript: TranscriptContext, options?: SimpleStreamOptions) {
  const output = createAssistantMessageEventStream();
  let terminal = false;
  let partial: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
    content: [], usage: emptyUsage(), stopReason: "pending", timestamp: Date.now() };
  void (async () => {
    try {
      if (options?.deferred) throw new Error("Native deferred generation is unsupported");
      await native("nativeModel", { chatID, systemPrompt: getCurrentSystemPrompt(transcript.messages),
        tools: getCurrentTools(transcript.messages), messages: transcript.messages.filter(message => message.role !== "system") },
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
