/** Explicit iOS entry: initialize JSC host APIs before opening native adapters. */
import "./host-api";
import { IOSAgentAdapter } from "./agent";
import { oxError } from "./ox-error";

export { deliver, streamEvent } from "./bridge";
const adapter = new IOSAgentAdapter();
export const agentCommand: IOSAgentAdapter["command"] = async args => {
  try { return await adapter.command(args); }
  catch (error) { throw oxError(error); }
};
