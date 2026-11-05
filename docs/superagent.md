# Super-agent Design (wip)

Ox has only one type of agent today, `@openox/agent` whose session maps 1 to 1 to a conversation.

Let's call it the Ox Agent.

The Ox Agent today mainly invokes execute tool to take actions via Code Mode, it is synchronous and blocked on the code to finish execution.

I want to have two types of agent: router agent and worker agent (current Ox Agent). Both of them should be implemented under `@openox/agent` with different prompts. Both of their prompts can reference from https://github.com/deepseek-ai/dsh-superagent-prototype while maintaining the existing structure.

A Router Agent borrows the idea from DSH Super-agent.

References:
1. https://x.com/DeepSeekHarness/status/2116857257245987236
1. https://github.com/deepseek-ai/dsh-superagent-prototype
