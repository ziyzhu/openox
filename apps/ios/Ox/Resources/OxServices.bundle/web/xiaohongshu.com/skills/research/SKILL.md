---
name: research
description: Search Xiaohongshu notes and assess the credibility of their claims and authors. Use for recommendations, comparisons, firsthand experiences, current trends, products, places, people, or claims when the work should include query refinement, counterevidence, comment review, author-history checks, commercial-bias checks, or corroboration across independent accounts.
---

# Research Xiaohongshu

Treat Xiaohongshu as a source of lived experience and leads, not automatically verified fact. Separate what a note says, how credible its author appears, and whether independent evidence supports the claim.

## Build searches

1. Restate the user's decision or question before searching.
2. Search in natural Chinese even when the request is in another language. Preserve proper names and model numbers.
3. Build focused queries from subject, context, constraint, desired outcome, location, and time. Search one query at a time with `searchNotes`.
4. Include counterevidence queries when relevant, such as `缺点`, `避雷`, `踩雷`, `翻车`, `劝退`, `长期使用`, `真实体验`, `实测`, and `对比`.
5. Add the current year or a specific season when freshness matters. Use `publishedAt` as a clue, not proof that every detail remains current.
6. Use `listTrending` only to discover current vocabulary or adjacent topics, never as evidence that a claim is true.

Prefer several narrow searches over one broad search. Do not assume likes or search position indicate reliability.

## Inspect evidence

1. Use `getNote` on a diverse set of promising results, including critical or lower-engagement notes when available.
2. Compare concrete details: dates, locations, prices, product variants, duration of use, measurements, constraints, and disclosed tradeoffs.
3. Use `listComments` to find corrections, recurring complaints, missing context, author answers, and vocabulary for follow-up searches.
4. Distinguish independent corroboration from repeated wording, reposts, or several accounts participating in the same campaign.
5. Preserve note URLs so the user can inspect the evidence.

Stop searching after the important conclusions are supported by three apparently independent authors, or when additional results only repeat existing evidence. If the available results cannot support a conclusion, report the gap instead of padding the answer.

## Check author credibility

For consequential claims or recommendations, call `getUserProfile`, then `listUserNotes`. Open representative older notes with `getNote` when the history needs closer inspection.

Assess the author on observable evidence:

- relevant history and sustained familiarity with the subject
- firsthand detail that fits the claimed experience
- consistency across biography, location, dates, and older posts
- willingness to state limitations, corrections, or mixed outcomes
- substantive responses to skeptical questions
- concentration of unrelated brand promotions, repetitive sales language, discount prompts, or abrupt category changes
- whether claimed credentials can be verified outside the profile when expertise materially affects the answer

Do not treat follower counts, accumulated likes, polished media, location, or a self-described title as proof of expertise or independence. Do not infer that a note is unsponsored merely because no commercial relationship is visible.

Describe credibility as `strong`, `mixed`, `weak`, or `indeterminate` and state the concrete reasons. Avoid numerical scores that imply unsupported precision.

## Synthesize

- Triangulate important conclusions across at least three apparently independent authors when the available results permit it.
- Separate direct observations, author claims, community consensus, disagreement, and your own inference.
- Explain material gaps, stale evidence, sign-in limits, or inaccessible posts.
- Lead with the useful conclusion, then summarize supporting and conflicting evidence with links.
- For medical, legal, financial, immigration, or safety decisions, use Xiaohongshu only to surface experiences and questions. Flag decisive claims for verification with authoritative primary sources; do not imply that this service performed that verification.
