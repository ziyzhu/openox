---
name: product-research
description: Research and compare Amazon products without changing the cart. Use when choosing among products, checking an exact listing or seller, comparing current offers, analyzing review patterns, or using Amazon rankings for product discovery.
---

# Research Amazon Products

Keep the workflow read-only. Do not call cart, checkout, tip, or order actions while using this skill.

## Define the comparison

1. Establish the use case, must-have features, compatibility, quantity or variant, budget, and delivery constraint.
2. Search with `searchProducts`. Use a department when the query is ambiguous and compare relevant sort orders rather than assuming `featured` means best.
3. Use rankings only for discovery. `bestsellers`, `new_releases`, and `movers_shakers` indicate marketplace activity, not suitability or quality.
4. Shortlist a small set of like-for-like listings. Keep variants, pack sizes, condition, and included accessories aligned.

## Verify each candidate

1. Call `getProduct` for exact listing facts and retain its ASIN or URL.
2. Call `getOffer` to identify the current seller, shipper, and whether Amazon sells or fulfills the offer. Do not imply that fulfillment proves product authenticity or seller quality.
3. Call `listReviews` for the rating distribution and a useful sample of reviews. Look for repeated use-case-specific strengths, failures, compatibility problems, durability reports, and changed product versions.
4. Distinguish product-page claims, current offer facts, individual customer reports, recurring review patterns, and your own inference.

Do not treat star averages, review counts, badges, rankings, polished copy, or a single enthusiastic or hostile review as decisive. The available actions do not establish that every review is authentic or that every listing represents the same revision.

## Compare and stop

- Compare current price, exact variant, seller and fulfillment, relevant features, review patterns, and material uncertainties in the same order for every finalist.
- Recheck the offer when price, seller, or delivery affects the recommendation because these can change independently of the product page.
- Stop after the leading candidates are clearly differentiated or additional results do not change the decision. Report a tie or evidence gap instead of inventing a winner.
- Lead with the best fit for the stated use case, not the most popular product. Include alternatives, tradeoffs, ASINs or links, and the time-sensitive offer facts behind the conclusion.
