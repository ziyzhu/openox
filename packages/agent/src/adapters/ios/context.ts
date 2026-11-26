import { section, type ConversationId } from "@earendil-works/pi-durable";
import type { Context } from "@earendil-works/chord/context";
import { ConversationApplicationMetadata, type ProfileRuntime } from "../../index";
import { composeIOSPrompt } from "./prompts";
import { composeOxTurnSections } from "../../core/ox-prompts";
import { filesSection, type SystemPromptInput, type TurnState } from "../../core/prompts";

const turnSectionKeys = ["skills", "hosts", "replies", "conversation_files", "storage", "language", "attached_services", "child_conversations"] as const;

async function composeFiles(session: ProfileRuntime, state: TurnState, conversationID: ConversationId | undefined) {
  return filesSection(await session.rootEntries(state.fileRoots), state.grantedFolders ?? [],
    session.files.physical && conversationID !== undefined ? `conversations/${conversationID}/` : undefined);
}

export async function composeContext(session: ProfileRuntime, promptState: SystemPromptInput, turnState: TurnState, conversationID?: ConversationId) {
  const turn = composeOxTurnSections(turnState, promptState);
  const sections: Record<string, string | undefined> = { ...composeIOSPrompt(promptState).sections };
  for (const key of turnSectionKeys) sections[key] = turn[key];
  sections.files = await composeFiles(session, turnState, conversationID);
  return { sections: Object.fromEntries(Object.entries(sections).filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1].length > 0)) };
}

export function conversationSections(session: ProfileRuntime, prompt: { sections: Record<string, string> }, promptState: SystemPromptInput,
  conversationID: ConversationId, context: Context) {
  const sections = Object.entries(prompt.sections).map(([key, text]) => section(key, () => text, { tag: key !== "preamble" }));
  const turnState = async ({ conversationId, read }: Parameters<Parameters<typeof section>[1]>[0]) =>
    (await read.snapshot(ConversationApplicationMetadata, conversationId, context))?.fields.turnState as unknown as TurnState | undefined;
  for (const key of turnSectionKeys) {
    sections.push(section(key, async input => {
      const state = await turnState(input);
      return state ? composeOxTurnSections(state, promptState)[key] : undefined;
    }));
  }
  sections.push(section("files", async input => {
    const state = await turnState(input);
    return state ? composeFiles(session, state, conversationID) : undefined;
  }));
  return sections;
}
