# Dimensions and coverage

Build coherent synthetic users by sampling a behavioral persona, a goal-oriented intent, and an eligible environment. Do not use demographic stereotypes. Keep the assigned persona stable for the whole session.

## Dimension registry

Cover these axes when the requested scope and current build support them:

| Axis | Representative values |
| --- | --- |
| Ox provider | Mock, configured real provider families, individual models, Global or China region |
| Model capability | text, image, PDF, tools, thinking, streaming |
| Persona | novice/familiar/expert; cautious/balanced/eager trust; low/medium/high patience; shallow/moderate/deep exploration; concise/balanced/detailed preference |
| Intent | quick answer, structured planning, multi-turn refinement, read-only app inspection, formatted explanation, ambiguity resolution, recovery |
| Appearance | creator-selected, light, dark |
| App language | English, Simplified Chinese, plus any language discovered in the current localization catalog |
| Prompt content | English, Simplified Chinese, mixed script, CJK and emoji, code and links, long structured text |
| Accessibility | semantic labels, large text, reduced motion, increased contrast, VoiceOver-relevant ordering when configurable |
| Input | short typing, long typing, multiline input, paste, supported attachments |
| Conversation | new, multi-turn, restored, compacted, model-switched |
| Lifecycle | foreground, background and return, cancellation and retry, relaunch |
| Provider condition | normal; Mock-controlled slow, error, rate-limit, truncation, or empty response; naturally observed real-provider failures |
| Tool boundary | no tool, read-only tool, approval, permission denial, safe recovery |
| Data shape | empty, ordinary, large, malformed, multilingual |
| Device | supported compact and large layouts, keyboard state, orientation when supported |
| Resource state | ordinary streaming, long output, memory pressure, focused performance reproduction |

Discover supported values from the checked-out repository and running app. Mark unsupported or unavailable values instead of pretending to exercise them.

Pass eligible axes not built into the planner as repeated `--dimension key=value1,value2` arguments. Useful discovered axes include model capability, attachment, tool boundary, permission state, data shape, device class, and resource state. The coordinator remains responsible for preparing safe fixtures and verifying that a selected value was actually exercised.

The planner records coverage targets, not completed coverage. Before delegation, turn targets such as `attachment=image` or `toolBoundary=permissionDenial` into exact fixtures, prompts, starting state, and user actions. A `modelSwitched` session needs named source and destination models plus switch timing; `cancelAndRetry` needs a cancellation trigger and retry policy. Only the final report may classify a target as attempted or covered.

## Persona and intent

Separate how the user behaves from what the user wants. Persona traits influence patience, exploration, corrections, approval decisions, and abandonment. The intent defines a goal and observable success condition without prescribing the exact UI route.

Examples:

- A cautious novice with low patience asks for a concise plan, rejects unnecessary permissions, and abandons after prolonged unexplained waiting.
- An expert with deep exploration asks Ox to inspect its current model and theme without changing either, then follows up on one detail.
- A familiar Chinese-speaking user requests a structured answer, backgrounds the app during streaming, and returns expecting coherent state.

## Sampling

Use a hybrid strategy:

1. Include at least one core smoke experience.
2. Cover eligible values individually before repeating them when the session budget permits.
3. Maximize uncovered pairs across provider, persona, intent, language, theme, lifecycle, and conversation state.
4. Guarantee high-risk pairs relevant to the request.
5. Use seeded randomness to break ties and explore higher-order combinations.
6. Avoid exact duplicate assignments inside one campaign.

Important pairs include real provider with multi-turn conversation, dark appearance with long streaming output, Simplified Chinese with large text, backgrounding with active work, model switching with restored conversation, slow response with low patience, permission denial with recovery, and compact layout with the software keyboard.

Do not promise exhaustive coverage of open-ended behavior. A finite catalog can be exhausted; the full combination space cannot. Report marginal coverage, relevant pairwise coverage, explicit gaps, and whether new sessions continue to produce new combinations or findings.

The skill is stateless across invocations. A fresh seed normally changes the selection but cannot guarantee cross-run novelty. When cumulative coverage is wanted, accept prior `/tmp/ox-gym.*/campaign.json` files explicitly as planner inputs; never maintain a hidden global ledger.

## Mock mapping

Use Mock to create deterministic UI and failure states. Current useful intents include:

| Experience | Mock intent |
| --- | --- |
| Quick streaming answer | `17` |
| Long output | `1` |
| Slow first token | `2` |
| Midstream error | `4` |
| CJK, emoji, and tables | `11` |
| Background streaming | `19` |
| Focused composer streaming | `21` |
| Parallel tools | `22` |
| Binary choice | `24` |
| Multi-choice flow | `25` |
| Recovery after tool error | `53` |
| Rate limit | `71` |
| App information | `80` |
| App-log approval | `90` |

Verify these keys against `MockLLMClient.Scenario.catalog` before relying on them because the catalog may evolve.

## Real providers

Use natural prompts with the same experience goal, not Mock's numeric control keys. Hold exact prompts constant across real-provider comparisons. Compare Mock and real providers on experience invariants rather than identical response content.

Real-provider sessions must be bounded by explicit target, call count, timeout, and allowed effects. Do not intentionally induce provider errors that would require credential manipulation, abusive traffic, or uncontrolled spend. Cancellation, backgrounding, safe read-only tool use, and naturally occurring failures are valid.
