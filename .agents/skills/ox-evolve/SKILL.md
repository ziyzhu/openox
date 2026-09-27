---
name: ox-evolve
description: Build or update Ox services through an Ox chat on a simulator, improve the shared authoring loop, notify developers of improvement opportunities, and promote verified Local web services into the built-in repository when requested. Use for development-driven service evolution and dogfooding the workflow users run directly in Ox.
---

# Evolve Ox

Ox evolves services in two ways:

- Development focused: a coding agent on the user's desktop drives Ox on a simulator to build or update services, observes the authoring loop, and improves it.
- User focused: users talk directly to their Ox to build or update services through the built-in `manage-services` system skill.

Both paths use the same Ox authoring workflow. Built-in services usually evolve through the development path, which also dogfoods and improves the experience available to users. Put reusable improvements in the shared runtime, tools, system skills, diagnostics, and verification so both paths benefit. Users evolving Local services do not need a desktop, simulator, or built-in promotion.

## Drive the development loop

Read the `sim-cli` and `ox-cli` skills for simulator operation and chat control. Use the user-selected simulator and its assigned Host endpoint; follow the repository's simulator setup and data-preservation rules.

1. Establish the requested service outcome and whether delivery is Local or built-in. A request to add or update a built-in service authorizes preparing its promotion after live verification; a Local-only request does not authorize publication.
2. Build, install, and launch the app as needed. Drive a real Ox chat through `skills/manage-services/SKILL.md` for discovery, exploration, action design, implementation, repair, and live verification. Follow its current planning, authentication, attachment, mutation, and Save boundaries.
3. Observe the user-visible flow with `sim` and inspect chat history and structured logs with `ox`. Look for unclear prompts, repeated failures, missing capabilities, unnecessary confirmations, poor recovery, and gaps in diagnostics or verification.
4. Notify developers of actionable findings as they emerge. Fix supported harness issues within the task's scope, rebuild as needed, and exercise the affected flow through Ox again. Return service defects and compiler diagnostics to Ox for repair and a newly verified saved revision.
5. Verify the requested outcome through actual service actions, including applicable authentication and handoff boundaries. Browser success alone does not verify a handler. Preserve evidence outside the repository and disclose unexecuted or partially verified actions.

Keep service behavior authored inside Ox. Do not substitute direct service source authoring, terminal browser capture, or inferred endpoint behavior for the Ox workflow. Coding agents can edit the app and authoring harness to improve the loop, but must verify the improvement through the same path users experience. Preserve the service manifest schema.

## Notify developers and improve the loop

Report actionable improvement opportunities promptly in the current developer session, including those already fixed. Give the triggering request or step, observed versus expected behavior, user impact, bounded sanitized evidence, and the proposed improvement. Include a chat or diagnostic reference when useful; exclude credentials and private user content.

Distinguish service-specific defects from reusable authoring-loop issues. Prefer fixing the shared cause over adding a one-off workaround. Update existing skills or steering files when the finding changes how future runs should work, and add the smallest meaningful regression coverage when warranted.

Use the current session as the notification destination unless the user specifies a developer channel or issue tracker. Send or file external notifications only within that authorization. Keep unresolved findings in the final handoff with their impact and next step; do not silently discard them because the service eventually succeeded.

## Deliver the service

For Local delivery, finish the built-in `manage-services` verification and Save workflow, then report the capability delivered, checks performed, limitations, and authoring-loop findings or fixes.

For requested built-in web-service delivery, read [references/promotion.md](references/promotion.md) after Ox has produced a verified, saved Local revision. Follow its export, sanitized replay, icon, bundle, and release checks. The exact saved Local implementation is the behavioral source of truth; promotion packages it without creating a second implementation.

Do not commit repository changes unless the user requests it. Report service delivery and developer findings separately so a working service does not hide remaining loop issues.
