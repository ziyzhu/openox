---
name: develop-services
description: Build or update Ox services through an Ox conversation on a simulator, improve the shared authoring loop, notify developers of improvement opportunities, and promote verified Local web services into the built-in repository when requested. Use for development-driven service evolution and dogfooding the workflow users run directly in Ox.
---

# Develop services

This desktop development skill is distinct from Ox's built-in `evolve` System skill.
Ox evolves services in two ways:

- Development focused: a coding agent on the user's desktop drives Ox on a simulator to build or update services, observes the authoring loop, and improves it.
- User focused: users talk directly to their Ox to build or update services through the built-in `skills/evolve/SKILL.md` System skill.

Both paths use the same Ox authoring workflow. Built-in services usually evolve through the development path, which also dogfoods and improves the experience available to users. Put reusable improvements in the shared runtime, tools, built-in guidance, diagnostics, and verification so both paths benefit. Users evolving Local services do not need a desktop, simulator, or built-in promotion.

## Drive the development loop

Read the `ios-simulator` and `ox-cli` skills for simulator operation and conversation control. Use the user-selected simulator and its assigned Host endpoint; follow the repository's simulator setup and data-preservation rules.

1. Establish the requested service outcome and whether delivery is Local or built-in. A request to add or update a built-in service authorizes preparing its promotion after live verification; a Local-only request does not authorize publication.
2. Build, install, and launch the app as needed. Drive a real Ox conversation through `skills/evolve/SKILL.md` for discovery, exploration, action design, implementation, repair, and live verification. Follow its current planning, authentication, attachment, and mutation boundaries. For conversation-local source backups, use complete authorized `ox.fs.read`/`ox.fs.write` exports; `ox.fs.copy` cannot transfer across service and conversation filesystem mounts.
3. Observe the user-visible flow with `idb` and inspect conversation history and structured logs with `ox`. Look for unclear prompts, repeated failures, missing capabilities, unnecessary confirmations, poor recovery, and gaps in diagnostics or verification.
4. Notify developers of actionable findings as they emerge. Fix supported harness issues within the task's scope, rebuild as needed, and exercise the affected flow through Ox again. Return service defects and compiler diagnostics to Ox for repair and newly verified source.
5. Follow Choose a favicon in Ox’s `skills/evolve/references/web-service.md` for every new service. Inspect screenshots of one actual small avatar in both themes and keep evidence outside the repository. Return failed candidates to Ox for repair; report unavailable visual verification as incomplete. Built-in promotion additionally follows `references/promotion.md`.
6. Verify the requested outcome through actual service actions, including applicable authentication and handoff boundaries. Browser success alone does not verify a handler. Preserve evidence outside the repository and disclose unexecuted or partially verified actions.

Keep service behavior authored inside Ox. Do not substitute direct service source authoring, terminal browser capture, or inferred endpoint behavior for the Ox workflow. Coding agents can edit the app and authoring harness to improve the loop, but must verify the improvement through the same path users experience. Preserve the service manifest schema.

## Notify developers and improve the loop

Report actionable improvement opportunities promptly in the current developer session, including those already fixed. Give the triggering request or step, observed versus expected behavior, user impact, bounded sanitized evidence, and the proposed improvement. Include a conversation or diagnostic reference when useful; exclude credentials and private user content.

Distinguish service-specific defects from reusable authoring-loop issues. Prefer fixing the shared cause over adding a one-off workaround. Update existing skills or steering files when the finding changes how future runs should work, and add the smallest meaningful regression coverage when warranted.

Use the current session as the notification destination unless the user specifies a developer channel or issue tracker. Send or file external notifications only within that authorization. Keep unresolved findings in the final handoff with their impact and next step; do not silently discard them because the service eventually succeeded.

## Copy Local source to the desktop

Use this workflow to copy a device's Local repository for inspection, backup, or requested promotion. It is a one-way snapshot, not a Git clone, sync, or authorization to promote services. Preserve the device's files and keep exports in a new private directory outside the checkout unless the user specifies another destination; never overwrite existing desktop files without confirmation.

Target the source Host explicitly, not the default simulator. For the user's iPhone, use `ws://iphone-17-pro-max.taile57b1f.ts.net:9876`, keep Tailscale connected, and keep Ox open. For a simulator, use its assigned endpoint. Select a loaded conversation in the intended Profile with `--conversation <full-id>`; follow the `ox-cli` skill if it needs hydration.

```sh
ox --host <ws-url> host repository list --json
ox --host <ws-url> --conversation <full-id> vm help ox.fs.list
ox --host <ws-url> --conversation <full-id> vm help ox.fs.read
ox --host <ws-url> --conversation <full-id> vm call ox.fs.list --args '{"purpose":"Export Local repository","path":"repositories/local/"}' --json
ox --host <ws-url> --conversation <full-id> vm call ox.fs.read --args '{"purpose":"Export repository metadata","path":"repositories/local/repository.json"}' --json
```

1. Confirm Local is available and choose the whole repository or the requested service subtree. Include `repository.json` for a repository snapshot and preserve all relative paths, including service resources and skills. Do not reconstruct source from conversation text or logs.
2. Recursively list each directory with `ox.fs.list`. Follow every `nextCursor` with the same path and options until complete; inspect `truncated` rather than assuming one page contains everything.
3. Read each text file with `ox.fs.read`. Follow `nextOffset` until `truncated` is false and write the decoded `text` to the matching desktop path, not the CLI JSON envelope. Preserve chunk boundaries exactly; do not add or remove newlines. Reject paths that escape the export directory.
4. Treat non-null `unsupported`, unreadable files, diagnostics, or truncation without continuation as incomplete. This text reader does not export binary bytes, and PDF reads extract text rather than the original file. Report those files and use a separately verified byte-preserving export route when needed; never silently omit them or claim a complete repository copy.
5. Avoid concurrent Local edits during export. Compare directory listings, file sizes, and modification times before and after; retry changed files and report that the API does not provide an atomic snapshot. Report exported paths, file count, and any incomplete files. For a complete repository, run `ox --repository <desktop-export-path> repository validate`; validation does not replace live service verification.

Copying out does not change source selection, reload attachments, or require a Files picker. `ox repository` operates on desktop paths or repository URLs; it cannot directly open an iPhone's virtual path. `ox.fs.copy` is not a device-to-desktop transfer command. Keep service repairs authored through Ox rather than editing the exported copy into a second implementation.

## Deliver the service

For Local delivery, finish the built-in `evolve` verification workflow, then report the capability delivered, checks performed, limitations, and authoring-loop findings or fixes.

For requested built-in web-service delivery, read [references/promotion.md](references/promotion.md) after Ox has produced verified Local source. Follow its export, live verification, icon, bundle, and release checks. The exact verified Local implementation is the behavioral source of truth; promotion packages it without creating a second implementation.

Do not commit repository changes unless the user requests it. Report service delivery and developer findings separately so a working service does not hide remaining loop issues.
