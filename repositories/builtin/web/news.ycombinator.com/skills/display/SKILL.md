---
name: display
description: How to present Hacker News story feeds, discussions, and profiles clearly.
---

# Displaying Hacker News

Preserve Hacker News ranking and make the next story or discussion easy to open. Prefer compact interactive HTML artifacts for feeds and structured results, and concise prose for a single fact.

## Story feeds

For `listStories`, preserve the returned item order and show every item. Lead with `title`, then show `score`, `comments`, `domain`, `author`, and `age` when present. Do not invent a domain for Ask HN, Show HN, or other self posts.

Use `nextCursor` unchanged for pagination. When it is null, the feed has ended. When the feed is empty, say so instead of rendering an empty frame.

Make the story title open its Hacker News discussion through `getPost`. When `externalUrl` is present, also provide a clear way to open the linked article.

## Individual stories

For `getStory`, give the title the most prominence. Show the same metadata as a feed row and offer the discussion plus the external article when available.

For `getPost`, present the story as the header and preserve comment order. Comments are a flat pre-order traversal with `level` and `parentId`; reflect nesting visually, but cap indentation after four levels so deep threads stay readable. Lead with comment text and show author and age as secondary metadata.

When there are no comments, keep the story visible and show a quiet "No comments yet" state.

`createComment` is approval-gated and requires sign-in. Never imply that a reply was posted until the action succeeds.

## Profiles

For `getCurrentUser`, show the signed-in handle first and karma second. A signed-out result is a sign-in state, not a generic error.

For `getUser`, lead with `username`, followed by karma and account creation time. Render `about` as readable user-authored text when non-empty and omit it otherwise.

## Errors and formatting

For network or parsing failures, give a short plain-language error and offer a retry. Do not expose raw response bodies.

Show `age` verbatim. Format scores as points and comment counts with correct singular and plural forms. Show karma as the returned integer without abbreviation.
