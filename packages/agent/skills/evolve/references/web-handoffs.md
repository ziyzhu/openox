# Website Bot Control and Payment

Read when implementing or repairing these standard handoffs. Add complete pairs, with both members `requireAuth: false` and `requireApproval: false`. The Host consumes their IDs through `ox.service.solve` and `ox.service.pay`, not ordinary exposed actions. Authentication uses `references/web-authentication.md`.

## Bot control

1. Identify the exact observed response showing that the originating action is blocked by human verification. Throw `BOT_CONTROL_REQUIRED` only for this state and direct the caller to `ox.service.solve` with the same operation-identifying inputs. Generic HTTP, parsing, authentication, and application failures are not bot control.
2. Add `getBotControlUrl(args): {url}` and `getBotControlState({...args, pageUrl}): {ok}`. Align operation inputs with the originating action; require `pageUrl` only on the state action because the Host supplies it while probing.
3. Return a browser-navigable challenge page that can be solved without an unsafe repeat of the originating effect. A challenge returned to fetch/XHR is not automatically in the visible document. The Host navigates and presents the same bot-control action page; its state probe must use fresh state there, not assume another page shares DOM or memory.
4. Define completion as the requested resource or effect existing, complete, and belonging to the operation inputs. Successful fetch, `2xx`, completed navigation, absent challenge elements, or generic authenticated pages are insufficient. Prefer an observed authoritative same-origin read with `credentials: "include"` and `cache: "no-store"`.
5. From live evidence, return `false` for exact challenge/submission/pending states, `true` only for the exact completed outcome, and throw for unknown status, redirect, response shape, parsing, CORS, or network failure. Keep probes cheap; the Host polls about once a second.
6. Preserve approval on the originating mutation. Solve authorizes no external effect beyond presenting and checking human verification. Verify the pair through `ox.service.solve` while pending and after human completion; unrelated success and challenge landing pages must never pass.
7. After solve resolves, inspect resulting state before retrying non-idempotent actions: the challenge page may already have completed the effect. Retry only when the effect is observably absent and the existing approval covers the attempt. Reads and safely idempotent operations may be retried directly.

## Payment

For transaction fulfillment, read `skills/checkout/SKILL.md`. Build missing support within the original request without a proposal checkpoint, then resume checkout. Final review and commitment belong to the user.

1. Keep preparation separate and approval-gated. Add `getPaymentUrl(args): {url}` for the prepared transaction.
2. Add `getPaymentState(args)` with required `status: "none" | "pending" | "completed"` and nullable `reference`, nonempty exactly when completed. Neither action may submit payment.
3. Add optional `total`, `currency`, `expiresAt`, and `completedAt` when useful; put itemized records in a separate action. Align episode-identifying inputs. Add optional `since` if needed to exclude earlier purchases; the Host supplies it at handoff start.
4. Preflight the favicon through `references/service-icon.md`, validate, attach or reload, and inspect the payment contract. Verify schemas, URL, and non-completed state without placing an order or charging to test the implementation.
5. Use `await ox.service.pay({ domain, args, purpose })` for review and payment. The Host opens checkout and resolves on completed state with a reference. Complete a real checkout only when authorized by the user's purchase request; never replace the handoff with a separate submission or charge action.

After cancellation, failure, timeout, or uncertainty, inspect fresh transaction status before another attempt. Do not automatically reopen checkout or repeat an effect. If status remains unknown, stop payment attempts and report it; cancellation is not permission to reopen.
