---
name: farm
description: "Use to find and connect Ox repositories from Ox Farm, update a connected repository to its reviewed commit, publish Local services and skills to a Git repository, list a repository on Ox Farm, or contribute a change to someone else's repository. Building or repairing a service or skill itself uses Evolve."
---

# Farm

Ox Farm is the reviewed index of Ox repositories. A repository is a Git repository holding services and skills; the farm lists each one at a reviewed commit. Complete the workflow the user asked for and stop; do not connect, publish, or register anything they did not request.

Work through the `openox.ai` service and the `ox.repository.*` functions. Inspect their live contracts before use and follow them over this text. When a function or action named here is missing, say that the step is not available in this version of Ox, give the manual alternative, and stop that workflow rather than improvising another route.

## Git hosts

Never assume a host. Take it from the repository URL and use the Ox service whose domain equals that host. Tell the user when no service exists for their host.

A Git host service supports this skill when it declares these actions; inspect it and use only the ones present:

| Action | Purpose |
| --- | --- |
| `createRepository` | Create an empty public repository owned by the signed-in account. |
| `forkRepository` | Fork a repository into the signed-in account. |
| `commitFiles` | Commit a set of files to a branch of a repository the account can write to. |
| `createPullRequest` | Open a pull request from a branch or fork. |

When website sign-in is needed for the host or the farm, read `skills/authentication/SKILL.md` and resume here after sign-in is verified. Never ask for passwords or tokens in conversation.

## Find and connect

1. Search with `searchRepositories`, using the user's words for the service, skill, or task. Offer the few best matches with name, author, whether ownership is verified, and what they add.
2. Read the chosen one with `getRepository`, following its cursor when the wanted service or skill is not on the first page. Tell the user which services and skills it adds, and name any action that changes something without asking for approval.
3. Connect with `ox.repository.connect`, passing the origin and commit from the result's `connect` value so the reviewed commit is installed. A null `connect` means the repository is included with Ox; say so and connect nothing.
4. Confirm the returned service and skill counts, then continue with the user's original task if there was one.

To update a connected repository, read it again with `getRepository` and connect again with the new commit; that replaces the existing connection in place. Syncing keeps a pinned repository on its commit.

## Publish

Publishing makes source public. Publish only the services and skills the user named, never all of Local by default.

1. Read each chosen package under `repositories/local/` and look for personal details: names, addresses, account identifiers, tokens, private URLs, and fixed defaults taken from the user's own requests. Show what you found and remove it with the user's agreement before continuing.
2. Package them with `ox.repository.export`. It validates each service and returns the archive path, the `repository.json` text, and the repository-relative file paths.
3. Establish the destination repository. Reuse one the user names; otherwise create one with the host service's `createRepository`.
4. Send `repository.json` and every listed file to the default branch with the host service's `commitFiles`, reading each file from `repositories/local/` at its listed path and keeping that path. Use the commit it returns in later steps.

If the host service has no `commitFiles`, give the user the exported archive and tell them to push its contents to their repository themselves.

## List

1. Confirm the repository is public and that the commit is on its default branch.
2. Register it with the farm's `registerRepository`, passing the repository URL and the full commit hash. It validates first; on failure, report the files and problems it returns and stop. Repair them through `skills/evolve/SKILL.md` only when the user asks.
3. On success, tell the user the submission is pending review and whether ownership was verified. The listing changes only after a reviewer approves.

Submitting a new commit for a registered repository uses the same action. If the farm service has no `registerRepository`, tell the user to submit the repository URL and commit on the Ox Farm website.

## Contribute

1. Read the repository with `getRepository` and confirm the change the user wants.
2. Fork it with the host service's `forkRepository`, or reuse the user's existing fork.
3. Make the change in Local through `skills/evolve/SKILL.md`, verify it, then send it to a branch of the fork as in Publish.
4. Open the request with `createPullRequest`, describing what changed and how it was verified. Report its URL.

The owner decides whether to merge and submits the new commit to the farm; do not register someone else's repository.

## Finish

Report what was connected, published, submitted, or opened, with the repository, commit, and any pending human step. Distinguish a pending review from a listed repository, and a published commit from a reviewed one.
