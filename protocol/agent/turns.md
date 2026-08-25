# Turns

A chat is an ordered sequence of semantic turns with stable identifiers. User
turns, agent generations, reasoning, text, executions, prompts, tool calls, and
effects are durable semantics. Client UI blocks and model-provider messages are
derived projections.

Running work is transient. When interrupted state is hydrated, nonterminal
turns and invocations become explicit cancelled or failed outcomes before the
chat is saved again.
