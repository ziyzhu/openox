---
name: clinical-trials
description: Search and interpret ClinicalTrials.gov study registrations and posted results. Use when finding trials, assessing registered eligibility and recruiting sites, comparing study designs, or summarizing registry results.
---

# ClinicalTrials.gov

Use this service as a public registry, not as medical advice, a treatment recommendation, or evidence that a study is safe, effective, or endorsed by the U.S. government.

## Find studies

1. Start with `searchStudies` and a short condition or intervention query.
2. Use `field: condition` for a diagnosis and `field: intervention` for a treatment. Use `all` when the user's wording spans several concepts.
3. For opportunities accepting participants, request `RECRUITING`, `NOT_YET_RECRUITING`, and, when relevant, `ENROLLING_BY_INVITATION` rather than relying on a word in the query.
4. Apply structured phase, study-type, sex, age, results, and update-date filters before adding `advancedQuery`.
5. Use `nearby` for a radius search. Use `location` for a named place when coordinates are unavailable.
6. Follow `nextCursor` only when more candidates are useful. Do not invent or edit cursors.
7. Call `getStudy` before giving detailed eligibility, contact, or design information.

## Read eligibility and recruitment

- Treat registered inclusion and exclusion criteria as screening information, not a determination that a person qualifies.
- Distinguish the study-wide `status` from each site's `status`. A recruiting study can include closed, unknown, or non-recruiting locations.
- Prefer a site's listed contact for site-specific availability. Use a central contact when a site has none.
- State the record's `lastUpdated` or the response `dataTimestamp` when timeliness matters. Contact information and recruiting status can lag operational changes.
- Preserve NCT identifiers and `sourceUrl` so the user can verify the registry record.
- Never contact investigators, submit personal health information, or imply enrollment has occurred. The service is read-only.

## Compare studies

Compare registered facts on the same axes:

- study status and nearby site status
- phase and study type
- randomized allocation, masking, and control groups
- intervention and comparator arms
- candidate age and sex ranges
- primary outcome and time frame
- enrollment count and whether it is anticipated or actual
- sponsor and last update date
- whether posted results exist

Keep factual comparison separate from clinical judgment. Do not rank a study as medically best. If the user wants a decision, suggest discussing the shortlist with a qualified clinician who knows their history.

## Read posted results

1. Confirm `hasResults` with `getStudy` or search with `hasResults: true`.
2. Call `getStudyResults` for structured participant flow, baseline measures, outcomes, analyses, adverse events, and limitations.
3. Report the registered outcome title, time frame, units, group labels, and analysis details together. Avoid comparing numbers whose populations, time frames, or units differ.
4. Distinguish posted registry results from peer-reviewed publication. Follow returned references when publication context is needed.
5. Mention truncation flags and counts. Raise `outcomeLimit` or `eventLimit` selectively instead of claiming a truncated response is complete.
6. Do not calculate unregistered clinical conclusions from incomplete aggregate fields. State when interpretation requires a statistician or clinician.

## Explain gaps

- An absent field usually means the sponsor did not register it in the returned record; do not infer a negative answer.
- `UNKNOWN` status is not the same as closed, completed, or recruiting.
- No posted results does not prove that no results or publications exist.
- Registry entries are supplied and updated by study sponsors or investigators. ClinicalTrials.gov does not independently verify every submitted claim.
