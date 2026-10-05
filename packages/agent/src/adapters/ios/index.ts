/** Explicit iOS entry: initialize JSC host APIs before opening native adapters. */
import "./host-api";
import { IOSAgentAdapter } from "./agent";

export { deliver, streamEvent } from "./bridge";
const adapter = new IOSAgentAdapter();
export const agentCommand: IOSAgentAdapter["command"] = args => adapter.command(args);
