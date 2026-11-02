# Website Bot Control and Payment

Human verification and payment use ordinary service actions and `ox.service.showPage`. No special URL or completion-detection actions, helper contracts, or polling are needed. Users mark completion themselves. Authentication uses `references/web-authentication.md`.

## Bot control

1. Identify the exact observed response showing that the originating action is blocked by human verification. Generic HTTP, parsing, authentication, and application failures are not bot control.
2. Leave the browser-navigable challenge on the action's live page. A challenge returned only to fetch/XHR is not automatically in the visible document. Prepare the visible challenge without an unsafe repeat of the originating effect.
3. Call `ox.service.showPage` with the same qualified action name, input, and session or pageUrl used for invocation. It presents that page without invoking, navigating, reloading, or creating a replacement. Never ask for challenge answers or tokens.
4. Preserve approval on the originating mutation. Showing a page grants no authority to repeat or expand its external effects. Verify user completion and cancellation without adding a detector.
5. After dismissal, inspect resulting state before retrying non-idempotent actions: the challenge page may already have completed the effect. Retry only when the effect is observably absent and the existing approval covers the attempt. Reads and safely idempotent operations may be retried directly.

## Payment

For transaction fulfillment, read `skills/checkout/SKILL.md`. Build missing support within the original request without a proposal checkpoint, then resume checkout. Final review and commitment belong to the user.

1. Prepare and price the transaction through ordinary service actions. Leave its actual checkout page ready for user review. Preparation must never submit an order or charge payment.
2. Preflight the favicon through `references/service-icon.md`, validate, attach or reload, and inspect the preparation actions. Verify the live page without placing an order or charging to test the implementation.
3. Call `ox.service.showPage` with the preparation action's qualified name and the same input and routing. The user reviews and commits on the merchant's page, then marks completion. Dismissal is acknowledgment, not verified payment confirmation. Retrieve order or receipt details through ordinary read actions when needed.
4. Complete a real checkout only when authorized by the user's purchase request; never replace the handoff with a separate submission or charge action.

Navigation can interrupt a preparation action's JavaScript result. Show its preserved live page without rerunning preparation; do not infer that the interrupted action succeeded. After cancellation, failure, timeout, or uncertainty, inspect fresh transaction status before another attempt. Do not automatically reopen checkout or repeat an effect. If status remains unknown, stop payment attempts and report it; cancellation is not permission to reopen.
