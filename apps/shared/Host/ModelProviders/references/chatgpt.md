# ChatGPT

## Official destinations

- Website: [Log in with ChatGPT](https://learn.chatgpt.com/docs/sign-in-with-chatgpt)
- Developer contract: [Open-source registration and login](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- Product information: [OpenAI Codex](https://openai.com/codex/)
- Help: [Codex collection in the OpenAI Help Center](https://help.openai.com/en/collections/14937370-codex)
- Account management: ChatGPT subscription and account settings. This integration does not use an OpenAI Platform API key.

## Ox account placement

Ox presents ChatGPT in Global. Treat it as a subscription-backed provider identity separate from the OpenAI API provider, even though both reuse the OpenAI Responses transport.

Ox uses OpenOx-named dynamic registration for the open-source, locally hosted ChatGPT plan flow. Identity and plan-use consent are separate; only validated identity and granted inference scopes establish a connection. Keep the issued registration tied to its user/workspace and use the public Responses API, never borrowed Codex client IDs or ChatGPT backend endpoints. Paid or remotely hosted offerings require separate eligibility review.

The new credential record is isolated from predecessor Codex credentials; existing users log in again. Retain old credentials without forwarding them to the public API. Verify actual predecessor/changed-build storage compatibility before release.

Use WebSocket continuation only on the same authenticated connection, with full-context recovery after connection loss and SSE fallback before stream events. OAuth bearer authentication does not require a legacy ChatGPT account header. HTTP requests must send full history with `store: false`, `stream: true`, and no `previous_response_id`; WebSocket `response.create` payloads omit HTTP streaming fields. Diagnose latency using the selected model reasoning effort, not the transport's default reasoning policy. Selecting a conversation starts authentication immediately and warms the connection once its durable conversation ID is ready, without a debounce or rendering or sending its prompt, tools, or draft. Bound the warmup ping to five seconds and the first WebSocket response event to fifteen seconds; do not apply that first-event deadline to ongoing reasoning or output. Send must not wait for unfinished preparation. On iOS backgrounding, cancel preparation and retire idle sockets; completed background requests must not leave idle pooled sockets. On foregrounding, retire suspect idle sockets and prepare the selected conversation again without interrupting active requests. Background-execution expiration cancels the active run while preserving received text; queued user submissions wait for foreground execution rather than replaying the interrupted turn. Verify OS background grants and natural expiration on a device; simulator lifecycle and injected-expiration checks validate policy, not those grants. Request-state warmup with `generate: false` reports input-token usage; require measured benefit before enabling it.

## Runtime sources

- Request authentication: [ChatGPTProvider.swift](../../Agent/LLM/Providers/ChatGPT/ChatGPTProvider.swift)
- OAuth: [ChatGPTOAuth.swift](../../Agent/LLM/Providers/ChatGPT/ChatGPTOAuth.swift)
- Account state: [ChatGPTSubscriptionAccount.swift](../../Agent/LLM/Providers/ChatGPT/ChatGPTSubscriptionAccount.swift)
- Definition, presentation, and model discovery: [providers.json](../providers.json)

## Implementation comparison

- Follow the first-party open-source contract above. Do not substitute historical Codex OAuth implementations for this registration and token contract.
