# Website Bot Control and Payment

Human verification and payment use ordinary service preparation actions followed by `ox.web.browser.showPage({ purpose, pageId })` on the exact owning page. The same function presents authoring challenges. Never substitute a different page. No special URL or completion-detection actions, helper contracts, or polling are needed. The page appears inline. Explain the user's step before calling. The handoff displays Done/Cancel and asynchronously waits, returning only `{ status: "completed" }` or `{ status: "cancelled" }` in the same execution and turn. Do not poll or continue dependent work while waiting. On cancelled, stop dependent work and do not reopen automatically. Done acknowledges interaction; inspect fresh state before continuing. Authentication uses `references/web-authentication.md`.

The agent owns task-specific readiness. Before requesting presentation, use preparation results or inspect the preserved service page with `ox.web.browser.getPageState({ frameId, purpose })`, using a fresh document target from browser.list with includeFrames:true, to establish the intended screen and usable controls. After cross-document navigation, inspect the new document rather than replaying preparation. The Host checks only mechanical availability and navigation readiness; it does not judge page content. A successful `showPage` acknowledgment does not prove the intended screen appeared or the task completed.

## Bot control

Before requesting user interaction, verify the actual live document contains the intended challenge or review step and the controls the user needs. Preparation handlers should establish this from current page evidence before returning when possible; after navigation interrupts their scripts, the agent inspects the preserved new document. A fetch response, URL, page title, or generic nonblank page is insufficient. If readiness cannot be verified, report the preparation failure and preserve the page instead of prompting the user to fix an unknown page. Do not replay a mutation to obtain that evidence.

1. Identify the exact observed response showing that the originating action is blocked by human verification. Generic HTTP, parsing, authentication, and application failures are not bot control.
2. Leave the browser-navigable challenge on the action's live page. A challenge returned only to fetch/XHR is not automatically in the visible document. Prepare the visible challenge without an unsafe repeat of the originating effect.
3. Call `ox.web.browser.showPage` with the exact owning pageId. Explain what the user needs to do before presenting the actual live challenge. Await the result in the same execution and turn. Inspect fresh state after completed; stop on cancelled. Do not bypass protection, ask for challenge answers or tokens, or treat presentation as completion. Showing a service page does not invoke, navigate, reload, or create a replacement.
4. Preserve approval on the originating mutation. Showing a page grants no authority to repeat or expand its external effects. Verify user completion and cancellation without adding a detector.
5. After the user reports completion, inspect resulting state before retrying non-idempotent actions: the challenge page may already have completed the effect. Retry only when the effect is observably absent and the existing approval covers the attempt. Reads and safely idempotent operations may be retried directly.

## Payment

For transaction fulfillment, read `skills/checkout/SKILL.md`. Build missing support within the original request without a proposal checkpoint, then resume checkout. Final review and commitment belong to the user.

1. Prepare and price the transaction through ordinary service actions. Leave its actual checkout page ready for user review. Preparation must never submit an order or charge payment.
2. Preflight the favicon through `references/service-icon.md`, validate, attach or reload, and reuse the returned preparation action contracts; inspect additional pages only when needed. Verify the live page without placing an order or charging to test the implementation.
3. Call `ox.web.browser.showPage` with the exact preparation pageId. Await the result while the user reviews and commits on the merchant's page, then chooses Done or Cancel. Resume the same execution and turn; stop on cancelled and inspect fresh state after completed. Presentation is not verified payment confirmation. Retrieve order or receipt details through ordinary read actions when needed.
4. Complete a real checkout only when authorized by the user's purchase request; never replace the handoff with a separate submission or charge action.

Navigation can interrupt a preparation action's JavaScript result. Show its preserved live page without rerunning preparation; do not infer that the interrupted action succeeded. After cancellation, failure, timeout, or uncertainty, inspect fresh transaction status before another attempt. Do not automatically reopen checkout or repeat an effect. If status remains unknown, stop payment attempts and report it; cancellation is not permission to reopen.
