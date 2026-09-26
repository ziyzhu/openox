# iOS end-to-end test prompts

Every `e2e/<test-case>.md` file is a self-contained prompt for a coding agent.
The agent drives a numbered QA simulator with `sim`, uses `ox` for Host-level
inspection, and reports evidence and cleanup. Scenario steps and assertions stay
in the prompt instead of executable test code.

Keep the directory flat and give each case a concise kebab-case filename. A case
prompt should define its scope, setup, user-visible flow, observable assertions,
failure evidence, and cleanup. It should prefer accessibility identifiers over
coordinates and keep screenshots, logs, mock servers, and other diagnostics
outside the repository.

Use prompt E2E cases for behavior that crosses visible UI, app lifecycle,
persisted state, and Host integration. The root `evals/` suite measures real-model behavior with Ox’s production
Agent loop and fixture-backed tools. Run it with `bun run evals`. LLM-related prompt cases belong here when the
behavior under test is the app experience, such as provider setup,
authentication, model switching, or persistence across relaunch.
