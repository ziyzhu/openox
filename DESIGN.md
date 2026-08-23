---
version: alpha
name: Ox
description: "A warm, provider-neutral personal assistant for iOS. The look should feel like the fruit it's named for: sun-warm, ripe, and unfussy."
colors:
  primary: "#FFA500"
  primary-pressed: "#D87A0A"
  surface: "#FFFFFF"
  surface-sunken: "#FDF2D9"
  background: "#F5F5F5"
  on-surface: "#000000"
  on-surface-muted: "#8E8E93"
  on-primary: "#FFFDF7"
  error: "#B8422E"
typography:
  display:
    fontFamily: SF Pro Rounded
    fontSize: 34px
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: -0.02em
  headline:
    fontFamily: SF Pro Rounded
    fontSize: 22px
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: -0.01em
  title:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.3
  body-md:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.45
  body-sm:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.4
  caption:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.3
  label-md:
    fontFamily: SF Pro Rounded
    fontSize: 15px
    fontWeight: 600
    lineHeight: 1.2
  mono-sm:
    fontFamily: SF Mono
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.4
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  xxl: 32px
  gutter: 16px
  margin: 16px
rounded:
  sm: 8px
  md: 12px
  lg: 18px
  xl: 24px
  full: 9999px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 14px
  button-primary-pressed:
    backgroundColor: "{colors.primary-pressed}"
  button-secondary:
    backgroundColor: "{colors.surface-sunken}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 12px
  link:
    textColor: "{colors.primary}"
    typography: "{typography.body-md}"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
    padding: 16px
  list-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    padding: 12px
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.md}"
    padding: 12px
  composer:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    padding: 10px
  toast:
    backgroundColor: "{colors.on-surface}"
    textColor: "{colors.surface}"
    rounded: "{rounded.full}"
    padding: 12px
---

# Ox Design System

## Overview

Ox is a provider-neutral personal assistant for iOS. Its primary surface is a streaming chat connected to website and device services, user-owned files, memory, and skills. The native app owns navigation, approvals, service handoffs, content libraries, and one compact Shoveler for displaying cards in chat; a card may open one referenced artifact, while agent-created interactive experiences remain self-contained HTML artifacts. The design system must keep those varied surfaces coherent without making the shell feel heavy.

The brand is steady, capable, and warm. **Ox feels grounded and strong without becoming heavy or stern** — a dependable working companion with an easy, informal voice. The warmth lives in the accents rather than the backdrop: surfaces stay clean and neutral so harvest gold and pale hay carry the temperature.

The voice is curious and direct. Native screens and agent-created artifacts should prefer **a few large, legible elements over dense layouts**. When in doubt: bigger type, more breathing room, fewer chrome lines.

## Colors

The accents come from a warm field palette — harvest gold and pale hay — laid over neutral surfaces so they read cleanly.

- **Primary — Harvest Gold (#FFA500):** The defining accent. Used for primary actions, active states, success, confirmation, and any element that anchors the user's attention. Saturated enough to read on white, never used as a large fill.

Surfaces are three tones, and only three:

- **Surface — White (#FFFFFF):** The content layer — cards, cells, inputs, and plain full-screen pages, including the chat canvas.
- **Background — Cloud (#F5F5F5):** The recessed sheet and grouped-screen backdrop. White cards sit on it to create settings-style depth.
- **Surface Sunken — Hay (#FDF2D9):** The one warm surface — chips, pills, secondary buttons, quiet emphasis. It is reserved for small accents, never whole backgrounds.

A chip always reads as one step off its backdrop: `surface-sunken` (hay) when it sits on white content, but **white (`surface`) when it sits on the grey `background`** of a grouped screen. Same chip, picked to contrast with whatever it's on.

**The rule:** white is content, `background` is the grouped backdrop behind it, `surface-sunken` is anything recessed *inside* content. If you're unsure which a thing is, it's almost always `surface`.

Text sits on these as **On-Surface — Ink (#000000)** for body and **On-Surface Muted (#8E8E93)** for metadata, captions, and disabled states. (Dark mode keeps the warmer near-black surface and cream-on-dark text; the neutral shift is a light-mode choice, but the same three-tone logic holds.)

## Typography

The type system uses Apple's SF Pro families, with **SF Pro Rounded for display and label roles** to keep the strong identity approachable, and **SF Pro for body** so long-form reading stays sharp. SF Mono shows up only for URLs and debug overlays.

- **Display / Headline:** SF Pro Rounded, semibold to bold, slightly tightened tracking. Used for screen and section titles.
- **Title:** SF Pro Semibold at body size — for list-row headers and card titles.
- **Body:** SF Pro Regular at 17px, the iOS native body size. Use it for chat, settings, service content, and artifact prose.
- **Caption / Muted:** SF Pro at 13–15px in `on-surface-muted` for timestamps, state, provenance, and other supporting metadata.
- **Label:** SF Pro Rounded Semibold for buttons and chips. Reinforces the friendly tone at the points the user actually touches.
- **Mono:** SF Mono for URLs, code, and debug surfaces.

The agent should not use more than two type sizes per visible region.

## Layout

Ox centers the active conversation and uses a sidebar for chats, artifacts, skills, services, and settings. The sidebar is a full-screen peer page in compact environments and may remain visible beside the chat on regular-width iPad. On compact layouts, a rightward swipe from the workspace opens the sidebar and a leftward swipe returns to the workspace; both pages also keep visible navigation controls. The compact sidebar bottom bar keeps chat search, settings, and new chat within reach, while regular layouts let native search follow the platform toolbar placement. The layout system is deliberately minimal:

- **One reading column.** Chat content and the composer use a centered readable-width column with a 16px phone margin. Full-screen artifacts own their internal responsive layout.
- **8-based scale with a 4px half-step.** All vertical rhythm is `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (24), or `xxl` (32). The default `VStack` spacing is `md` (12).
- **Generous touch targets.** Any `Button` is at least 44pt tall; the agent should pad rather than shrink.
- **The composer lives at the bottom.** Service handoffs dock immediately above it; neither surface becomes a persistent card in message history.

Spacing tokens keep chat, libraries, settings, sheets, and handoff surfaces recognizably part of the same product.

## Elevation & Depth

Ox is a **flat, tonal design** — no drop shadows, no borders. Depth comes from the three-surface stack:

- Plain screens, sheets, and the chat canvas sit on `surface` (white).
- Grouped screens put their cards on `surface` and the page behind them on `background` (cloud) — the white-on-cloud contrast is the only separation needed.
- Small recessed accents — chips, pills, secondary buttons — use `surface-sunken` (pulp).

Layers are told apart by tone alone. A card never gets a hairline and an input never gets a ring; if two things need separating, change the tone, don't draw a line. If a future feature genuinely needs a shadow (a sheet, a popover), keep it soft and low-opacity.

## Shapes

The shape language is **soft, broad, and continuous**. Strength comes from stable proportions rather than sharp corners.

- Buttons, inputs, list rows, and cards all use `rounded.md` (12px) by default.
- Standalone settings rows use capsules, matching the default Liquid Glass shape. Grouped settings surfaces use `rounded.xl` (24px) so multi-row and larger content does not become excessively round.
- Larger surfaces (cards containing rich content, sheets) use `rounded.lg` (18px).
- Chips use `rounded.full` and a 32px height. Toasts also use `rounded.full`.
- Avoid `rounded.sm` (8px) except for nested elements inside an already-rounded container.
- Never use sharp 90° corners on an interactive element.

There are no borders. Surfaces are separated by tone, not hairlines — an input is a `surface` fill on a `background` page, not a stroked rectangle.

## Components

The component tokens below describe how native SwiftUI surfaces should be styled when they take on common roles. Interactive artifacts use the same visual defaults without pretending to be native controls.

- **Button (primary):** Filled `primary`, `on-primary` text, 12px radius, ~14px padding, label typography. One per screen if possible — this is the "bite" action.
- **Button (secondary):** `surface-sunken` fill, `on-surface` text. Used for everything that isn't the headline action: filters, "show more", view toggles.
- **Link:** Inline `primary` color on body type. Used when the agent is surfacing a navigable item from the page (a story title, an author, a comment thread).
- **List row:** `surface` background, `body-md` text, 12px vertical padding. Rows separate from the `background` page by tone, not by a divider. The default container the agent reaches for when it has a list of N things.
- **Settings surface:** `surface` background with the same row typography and padding. Use a capsule for standalone rows, fields, and actions to match the default Liquid Glass shape; use the shared `rounded.xl` group shape for multi-row and larger content. Pad row content by 14px on every edge. Inset section headers and supporting copy by 14px to keep their text aligned with row content. Give dividers that same 14px inset on both ends.
- **Card:** `surface`, `rounded.lg`, 16px padding, sitting on a `background` page. For a single rich item the agent wants to feature (a top story, a summary, a generated answer).
- **Input:** `surface` fill, 12px radius, no border. Focus is shown by the cursor, not a ring.
- **Composer:** `surface` background, anchored at the bottom of chat, with attachment, service, text-entry, send, and stop states sized for thumb reach.
- **Service chip:** `surface-sunken`, `rounded.full`, and 32px height, with the service identity and a trailing authentication status: a muted filled check when signed in, a muted hollow circle when signed out or authentication is unavailable or unnecessary, and a spinner while checking or signing in. A tap opens service details. A long press offers Remove plus the state-appropriate sign-in or sign-out action; loading and sign-in-not-required states are shown disabled.
- **Scope chip:** `surface-sunken`, `rounded.full`, and 32px height, with the scope identity and a trailing remove action. Scopes wrap within their service row. The matching add chip uses the same shape, fill, typography, and spacing and opens the system picker that creates another scope.
- **Handoff dock:** A compact glass surface immediately above the composer with one service identity, one short instruction, and one 44pt primary action. Sign-in and verification never become transcript cards; success briefly changes the action to a checkmark, then the dock collapses.
- **Interactive artifact:** A dedicated full-screen HTML canvas with only Ox's close control above it. The artifact owns its internal visual language, but should default to one phone-width column, native body type, generous targets, and warm accents.
- **Toast:** Ink-on-hay pill (`on-surface` fill, `surface` text), `rounded.full`. The agent uses these for transient acknowledgements ("Summarizing…").

States are layered onto these via `*-pressed`, `*-disabled` variants that adjust only background or text color — never radius, never size — so the layout doesn't reflow on touch.

## Do's and Don'ts

- **Do** keep surfaces neutral — white content on a mist `background`. The warmth comes from the orange and the pulp accents, not the backdrop.
- **Do** use `primary` (Harvest Gold) for at most one element per visible region. It loses meaning the moment there are two.
- **Do** prefer larger type and fewer items. The agent has license to drop content the user didn't ask for.
- **Do** use `on-surface` for text and `on-surface-muted` for metadata and disabled states.
- **Don't** add borders or shadows to separate layers — tone does that. Don't spread `surface-sunken` cream across a whole background; it's a small-accent tone now.
- **Don't** mix radii on a single screen — pick `md` or `lg` and stay there.
- **Don't** stack two or more `primary`-colored elements adjacent to each other.
- **Do** keep service pages behind the credential firewall during ordinary assistant work; present the real page only for explicit browsing, authentication, bot control, or payment review.
- **Don't** use SF Mono outside URLs, code, and debug surfaces — it cools the palette instantly.
