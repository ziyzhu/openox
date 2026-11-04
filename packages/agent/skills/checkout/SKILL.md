---
name: checkout
description: "Use when preparing a purchase, booking, or payable order and carrying it through user review, payment, and verified confirmation, including when missing service support must be added. Product research or price comparison without a transaction does not require this skill."
---

# Checkout

Carry the requested transaction through preparation, user review and payment, and verified confirmation. Continue discovery, selection within the user's requirements, cart preparation, pricing, and service authoring without proposal checkpoints or asking whether to proceed. The planned user handoff is final transaction review and payment. Pause earlier only for consequential missing information, login, human verification, runtime Action approvals, or concrete blockers. Honor Action policies without adding a second approval form or changing policies to avoid a gate.

## Prepare

Identify the merchant's domain from the request or public research, attach its existing service, and inspect its preparation and read actions with `ox.service.inspect`. If no implementation exists or the needed actions are missing, use Evolve to build or extend the service, then invoke it; bundled coverage does not limit merchant support. Inspect the full contracts of needed actions before calling `ox.service.invoke`. Reuse the existing cart, booking, or order when it matches the request; preserve unrelated items and completed effects.

Prepare and price the transaction through service actions. Resolve items, quantities, dates, delivery or fulfillment, and required account details from the request and authorized current state. Ask only when a missing choice prevents progress. Establish the merchant, itemized charges, discounts, taxes, fees, shipping, final total and currency, and applicable recurring charges, cancellation or refund terms. Surface unavailable or provisional amounts and material changes before commitment. Keep credentials in the service's secure user flow; never request payment secrets in conversation or store them in service source.

## Add missing support

If preparation actions are missing or broken, read `skills/evolve/SKILL.md` and `skills/evolve/references/web-service.md`. Implement and verify the missing support on the fly within the original request, without a proposal checkpoint. Use Browser to observe actual checkout behavior and implement or repair missing service actions, not to bypass missing service support. Inspect existing Local source and create or copy an editable service through the normal evolve workflow. Resume transaction preparation through verified service actions. Preserve unrelated Local changes and existing runtime gates.

Use ordinary preparation actions to leave the actual checkout page ready for user review. They must not submit payment or an order. Present that same live page with `ox.service.showPage`; no special URL or completion-detection actions are needed. The page appears inline and the call returns immediately; the user reports checkout completion in chat. User acknowledgment, a checkout page, successful navigation, HTTP success, or an unrelated past order is not verified payment confirmation.

Validate the complete service, attach it to reload, inspect its preparation contracts, and verify the live checkout page before handoff. Never place an order or make a charge to test the implementation. Continue to the original checkout after verification. If reliable preparation or payment support cannot be implemented, report the concrete blocker and stop before further transaction-changing steps. Do not fall back to browser-only execution, bypass the user payment handoff, or claim verified completion.

## Review and pay

Present the prepared transaction's material details and call `await ox.service.showPage({ purpose, name, input, session, pageUrl })` with the preparation action's qualified name and the same input and routing used for invocation; omit unused routing fields and never combine session and pageUrl. This is the review and payment handoff; do not ask for a separate chat confirmation first. The user reviews and commits on the merchant's page. Do not invoke a separate charge or order-submission action as a substitute. Invoke the website's login action for authentication, and show the blocked action's live page for human verification. Navigation can interrupt preparation; show the preserved page without rerunning the action.

## Verify and recover

`ox.service.showPage` returning only confirms presentation, not user interaction or payment. End the turn after showing the page; do not poll or continue dependent work. When the user reports completion, retrieve available order or receipt details through exposed read actions and report the amount, currency, confirmation reference, and relevant next steps. Distinguish user-reported completion from verified payment and later fulfillment; do not claim verified confirmation without supporting details.

On cancellation, failure, timeout, or an uncertain result, inspect fresh transaction status through read actions before considering another attempt. Do not automatically reopen checkout, resubmit, or repeat a completed effect. If the outcome remains unknown, state that and stop payment attempts. If payment is observably incomplete, ask whether the user wants to resume; cancellation is not permission to reopen checkout.
