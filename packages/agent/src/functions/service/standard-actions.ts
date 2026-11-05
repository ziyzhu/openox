import { CONVERSATION_ACTION_SCHEMA, MODEL_ACTION_SCHEMAS } from "@openox/protocol/model-actions";
import actions from "./standard-actions.json";

export const standardServiceActions = {
  ...actions,
  web: [
    ...actions.web,
    { id: "listModels", description: "Optional website model choices. This does not register an Ox model provider.", ...MODEL_ACTION_SCHEMAS.listModels! },
    { id: "conversation", description: "Optional website submit/read/cancel workflow. Submit once, retain submissionId, and read bounded events until completion. Inspect uncertain submission state rather than replaying it. Runtime approvals apply to consequential submissions.", ...CONVERSATION_ACTION_SCHEMA },
  ],
};
