---
name: checkout
description: "Use to prepare a purchase, booking, or payable order through user review, payment, and verified confirmation, including adding missing service support. Research or price comparison without a transaction does not require this skill."
---

# Checkout

Prepare the requested transaction, hand final review and payment to the user, then verify confirmation. Continue predictable discovery, selection, pricing, and authoring without proposal checkpoints. Pause for consequential missing choices, login, human verification, runtime approvals, or blockers. Honor Action policies without adding approval forms or changing policies to avoid gates.

## Prepare

Identify the merchant, attach its service, and inspect needed preparation/read contracts. Reuse matching carts, bookings, or orders; preserve unrelated items and completed effects. Missing repository coverage does not limit merchant support.

Resolve items, quantities, dates, delivery, fulfillment, and account details from the request and authorized state. Establish itemized charges, discounts, taxes, fees, shipping, final total/currency, recurring charges, and material cancellation/refund terms. Disclose provisional amounts and material changes before commitment. Never request payment secrets in chat or store them in source.

Preparation actions must leave the actual checkout page human-readable and ready for review without submitting an order or payment. If support is missing or broken, read `skills/evolve/SKILL.md`, its web-service reference, and `skills/evolve/references/web-handoffs.md`. Observe through Browser, build or repair within the original request, validate, reload, and verify through service actions. Preserve Local work and runtime gates; never place an order or charge merely to test. If reliable support remains blocked, stop transaction-changing work and report the blocker, not a browser-only fallback.

## Review and pay

Present material transaction details, then call `await ox.service.showPage({ purpose, name, input, session, pageUrl })` with the preparation action's original qualified name, input, and routing, preserving omitted fields. `session` and `pageUrl` may both be supplied. Do not request separate chat confirmation: the user reviews and commits on the merchant's page. Never substitute a charge or order-submission action. Use the website's login action for authentication and the blocked action's live page for human verification.

If navigation interrupts preparation, show its preserved page without rerunning it or claiming success. No special URL or completion-detection actions are needed. showPage returns immediately; explain the user's step and end the turn without polling or continuing dependent work.

## Verify and recover

Presentation, acknowledgment, successful navigation/HTTP, and unrelated past orders are not payment confirmation. After the user reports completion, retrieve available order/receipt details through read actions. Report amount, currency, confirmation reference, and next steps; distinguish user-reported completion, verified payment, and later fulfillment.

After cancellation, failure, timeout, or uncertainty, inspect fresh transaction status before another attempt. Never automatically reopen checkout, resubmit, or repeat completed effects. If status stays unknown, report it and stop payment attempts. If payment is observably incomplete, ask whether to resume; cancellation grants no permission to reopen.
