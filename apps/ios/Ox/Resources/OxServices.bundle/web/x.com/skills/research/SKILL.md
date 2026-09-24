---
name: research
description: Research claims, events, trends, and accounts on X with thread context and source assessment. Use when investigating posts, reactions, timelines, or an author's credibility, including focused searches, thread reconstruction, posting-history checks, and corroboration across independent accounts.
---

# Research X

Treat posts, engagement, trends, and profile claims as leads rather than verified facts. Separate what an account posted, what replies allege, what independent accounts corroborate, and what remains unknown.

## Find relevant posts

1. Define the claim, event, account, and time window before searching.
2. Use `searchTweets` with a focused query. Use exact phrases, `from`, link or media filters, and date constraints when they materially narrow the evidence.
3. Use `product: live` for recent posts and `top` for prominent posts. Compare both when popularity might hide chronology or dissent.
4. Exclude replies or retweets when looking for original claims. Search replies separately when public reaction matters.
5. Use `listTrending` only to discover current vocabulary or related topics, never as evidence that a claim is true or broadly believed.

## Restore context

1. Call `listThread` before interpreting a post that is part of a conversation. Follow pagination when later replies materially affect the meaning.
2. Distinguish the original author, the author's follow-ups, quoted material, and replies from other accounts.
3. Use `getArticle` when a post links to an X Article; do not summarize the teaser as though it were the complete article.
4. Preserve post or article links for the user.

## Assess sources

For consequential claims, call `getProfile` and inspect representative recent posts with `listTweets`.

Assess observable signals:

- relevant history and sustained familiarity with the subject
- proximity to the event or access to primary material
- concrete dates, documents, media, or reproducible details
- consistency between the profile, chronology, and prior posts
- corrections, uncertainty, and substantive engagement with challenges
- repeated promotional, partisan, or engagement-bait patterns

Do not treat follower counts, likes, reposts, a Blue subscription, or Blue-verified followers as proof of identity, expertise, independence, or truth. Do not infer that several reposts are independent corroboration.

Describe source credibility as `strong`, `mixed`, `weak`, or `indeterminate` and state the observable reasons. Keep source credibility separate from whether a particular claim is supported.

## Conclude

- Triangulate important conclusions across at least three apparently independent accounts when results permit it.
- Stop when additional searches repeat existing evidence. If only one source exists or chronology remains incomplete, report that limitation.
- Separate direct evidence, account claims, community reaction, disagreement, and your own inference.
- Lead with the conclusion, then give the chronology, supporting and conflicting evidence, source assessment, and links.
- Flag medical, legal, financial, safety, or fast-moving factual claims for verification with authoritative primary sources; do not imply that X performed that verification.
