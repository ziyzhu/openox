---
name: checkout
description: "Prepare a purchase, booking, or payable order, add missing payment support on the fly, and hand final transaction review and payment to the user."
---

# Checkout

Carry the requested transaction through preparation, user review and payment, and verified confirmation. Continue discovery, selection within the user's requirements, cart preparation, pricing, and service authoring without proposal checkpoints or asking whether to proceed. The planned user handoff is final transaction review and payment. Pause earlier only for consequential missing information, sign-in, human verification, runtime Action approvals, or concrete blockers. Honor Action policies without adding a second approval form or changing policies to avoid a gate.

## Prepare

Discover the merchant's service with `ox.service.find`, read its manifest, attach it, and inspect its exposed actions and `payment` contract with `ox.service.inspect`. Inspect the full contracts of needed actions before calling `ox.service.invoke`. Reuse the existing cart, booking, or order when it matches the request; preserve unrelated items and completed effects.

Prepare and price the transaction through service actions. Resolve items, quantities, dates, delivery or fulfillment, and required account details from the request and authorized current state. Ask only when a missing choice prevents progress. Establish the merchant, itemized charges, discounts, taxes, fees, shipping, final total and currency, and applicable recurring charges, cancellation or refund terms. Surface unavailable or provisional amounts and material changes before commitment. Keep credentials in the service's secure user flow; never request payment secrets in conversation or store them in service source.

## Add missing support

If preparation actions or the `payment` contract are missing or broken, read `skills/evolve/SKILL.md` and `skills/evolve/references/web-service.md`. Implement and verify the missing support on the fly within the original request, without a proposal checkpoint. Use Browser to observe actual checkout behavior and implement or repair missing service actions, not to bypass missing service support. Inspect existing Local source and create or copy an editable service through the normal evolve workflow. Resume transaction preparation through verified service actions. Preserve unrelated Local changes and existing runtime gates.

Use the standard payment pair: `getPaymentUrl(args)` returns `{url}` for the prepared transaction; `getPaymentState(args)` returns `status: "none" | "pending" | "completed"` and nullable `reference`, with a nonempty reference exactly when completed. Correlate the probe to this cart, booking, or order; use an optional `since` input when needed to exclude earlier purchases. A checkout page, successful navigation, HTTP success, or unrelated past order is not payment confirmation. Neither action may submit payment.

Validate the complete service, attach it to reload, inspect its payment contract, and verify the URL and non-completed state before handoff. Never place an order or make a charge to test the implementation. Continue to the original checkout after verification. If reliable preparation or payment support cannot be implemented, report the concrete blocker and stop before further transaction-changing steps. Do not fall back to browser-only execution, bypass the user payment handoff, or claim verified completion.

## Review and pay

Present the prepared transaction's material details and call `await ox.service.pay({ purpose, domain, args })` using the inspected service-specific arguments. This is the review and payment handoff; do not ask for a separate chat confirmation first. The user reviews and commits on the merchant's page. Do not invoke a separate charge or order-submission action as a substitute. Use `ox.service.signIn` and `ox.service.solve` for supported authentication and human-verification interruptions, then resume the transaction.

## Verify and recover

After `ox.service.pay` resolves, inspect the completed state and reference, retrieve available order or receipt details through exposed read actions, and report the amount, currency, confirmation reference, and relevant next steps. Distinguish payment completion from later fulfillment.

On cancellation, failure, timeout, or an uncertain result, inspect fresh transaction status through read actions before considering another attempt. Do not automatically reopen checkout, resubmit, or repeat a completed effect. If the outcome remains unknown, state that and stop payment attempts. If payment is observably incomplete, ask whether the user wants to resume; cancellation is not permission to reopen checkout.
