# Messages

Status: Draft.

Agent input combines the selected Profile context, prior semantic turns, the
current user request, available skills, and VM tool contracts. Agent output is
provider-neutral text, reasoning, tool activity, prompts, effects, and usage.

Provider adapters may transform this representation for a model API, but
provider request identifiers, wire blocks, and proprietary reasoning formats
are not portable Profile semantics.
