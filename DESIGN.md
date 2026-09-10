---
version: alpha
name: Ox
description: "A warm, provider-neutral personal assistant for iOS. Grounded, capable, and unfussy, with soft shapes and a harvest-gold accent."
colors:
  primary: "#FFA500"
  primary-pressed: "#D87A0A"
  surface: "#FFFDF7"
  surface-sunken: "#FBE9C7"
  chip-on-background: "#FBE9C7"
  chat-surface: "#FFFFFF"
  bubble: "#FBE9C7"
  background: "#FFF6E6"
  on-surface: "#3A2410"
  on-surface-muted: "#7A5A3A"
  on-primary: "#FFFDF7"
  error: "#B8422E"
typography:
  display:
    fontFamily: SF Pro Rounded
    fontSize: 34px
    fontWeight: 700
  headline:
    fontFamily: SF Pro Rounded
    fontSize: 22px
    fontWeight: 600
  title:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 600
  body-md:
    fontFamily: SF Pro
    fontSize: 17px
    fontWeight: 400
  body-sm:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 400
  caption:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 400
  caption-md:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 600
  caption-sm:
    fontFamily: SF Pro
    fontSize: 11px
    fontWeight: 600
  label-md:
    fontFamily: SF Pro Rounded
    fontSize: 15px
    fontWeight: 600
  mono-sm:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
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
    rounded: "{rounded.full}"
    paddingHorizontal: 12px
    height: 32px
    minimumTouchTarget: 44px
  button-primary-pressed:
    backgroundOpacity: 0.7
  button-secondary:
    backgroundColor: "{colors.chip-on-background}"
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    paddingHorizontal: 12px
    height: 32px
    minimumTouchTarget: 44px
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
  settings-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.full}"
    paddingHorizontal: 20px
    paddingVertical: 14px
  composer:
    backgroundMaterial: regular-glass
    textColor: "{colors.on-surface}"
    rounded: "{rounded.xl}"
  toast:
    backgroundMaterial: regular-glass
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    paddingHorizontal: 14px
    paddingVertical: 10px
  toast-error:
    backgroundMaterial: regular-glass
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.xl}"
    paddingHorizontal: 14px
    paddingVertical: 10px
---

# Ox Design System

## Overview

Ox is a provider-neutral personal assistant for iOS. Its primary surface is a streaming chat connected to website and device services, user-owned files, memory, and skills. The native app owns navigation, approvals, service handoffs, content libraries, and one compact Shoveler for displaying cards in chat; a card may open one referenced artifact, while agent-created interactive experiences remain self-contained HTML artifacts. The design system must keep those varied surfaces coherent without making the shell feel heavy.

The brand is steady, capable, and warm. **Ox feels grounded and strong without becoming heavy or stern** — a dependable working companion with an easy, informal voice. The default Ox theme uses cream surfaces, brown text, and harvest gold. Light and Dark offer neutral alternatives with the same warm accent.

The voice is curious and direct. Native screens and agent-created artifacts should prefer **a few large, legible elements over dense layouts**. When in doubt: bigger type, more breathing room, fewer chrome lines.

This document describes the current native implementation and provides defaults for HTML artifacts. Shared native tokens live in [Theme.swift](apps/ios/Ox/Client/UI/Theme.swift); individual components own their layout and state variants. The frontmatter uses the default Ox palette. Its `px` dimensions are CSS equivalents for artifacts; native layout uses points and semantic fonts that support Dynamic Type. Generic card, list-row, and input tokens are artifact defaults, not universal native component styles. Primary and secondary button tokens describe the shared chip buttons; native exceptions are listed below.

## Colors

Ox has three explicit themes: **Ox** (`creatorPick`, the default), **Light**, and **Dark**. Ox and Light use the light color scheme; Dark uses the dark color scheme.

| Token | Ox | Light | Dark |
| --- | --- | --- | --- |
| `primary` | `#FFA500` | `#FFA500` | `#F5A030` |
| `primary-pressed` | `#D87A0A` | `#D87A0A` | `#C77410` |
| `surface` | `#FFFDF7` | `#FFFFFF` | `#1C1C1E` |
| `surface-sunken` | `#FBE9C7` | `#F2F2F7` | `#2C2C2E` |
| `chip-on-background` | `#FBE9C7` | `#FFFFFF` | `#2C2C2E` |
| `chat-surface` | `#FFFFFF` | `#FFFFFF` | `#0A0A0A` |
| `bubble` | `#FBE9C7` | `#F2F2F7` | `#1C1C1E` |
| `background` | `#FFF6E6` | `#F5F5F5` | `#0A0A0A` |
| `on-surface` | `#3A2410` | `#000000` | `#ECECEC` |
| `on-surface-muted` | `#7A5A3A` | `#8E8E93` | `#9A9A9A` |
| `on-primary` | `#FFFDF7` | `#FFFDF7` | `#FFFDF7` |
| `error` | `#B8422E` | `#B8422E` | `#E25A45` |

Use `surface` for content and settings rows, `background` for grouped pages, and `chat-surface` for the conversation canvas. `surface-sunken` supports small recessed accents; `bubble` is a separate message token. Chips on grouped pages use `chip-on-background`, which is white in Light and hay in Ox. Composer chips use glass instead of an opaque token fill.

Harvest gold marks primary actions, active states, and confirmation. Keep its emphasis selective. Body text uses `on-surface`; metadata and supporting text use `on-surface-muted`. Resolve colors through the selected theme rather than assuming that content is always white or text is always black.

## Typography

The type system uses **SF Pro Rounded for display and label roles**, SF Pro for body text, and a monospaced system font for URLs, code, and diagnostics. Native tokens use SwiftUI semantic text styles, not fixed pixel sizes or custom line-height and tracking values.

| Token | Native style | Design / weight |
| --- | --- | --- |
| `display` | `.largeTitle` | Rounded, bold |
| `headline` | `.title2` | Rounded, semibold |
| `title` | `.headline` | Default |
| `body-md` | `.body` | Default |
| `body-sm` | `.subheadline` | Default |
| `caption` | `.caption` | Default |
| `caption-md` | `.caption` | Semibold |
| `caption-sm` | `.caption2` | Semibold |
| `label-md` | `.subheadline` | Rounded, semibold |
| `mono-sm` | `.caption` | Monospaced |

The frontmatter gives nominal artifact sizes; native text scales with the user's text-size setting. Prefer a small number of type roles per visible region. See Apple's [SwiftUI Font documentation](https://developer.apple.com/documentation/swiftui/font) for the native font model.

## Layout

Ox centers the active conversation and uses a sidebar for chats, artifacts, skills, services, and settings. The sidebar is a full-screen peer page in compact environments and may remain visible beside the chat on regular-width iPad. On compact layouts, a rightward swipe from the workspace opens the sidebar and a leftward swipe returns to the workspace; both pages also keep visible navigation controls. The compact sidebar bottom bar keeps chat search, settings, and new chat within reach, while regular layouts let native search follow the platform toolbar placement. The layout system is deliberately minimal:

- **One reading column.** The shared readable-width limit is 700pt. Keep equal outer-edge padding; 16pt is the general phone margin, with component-specific insets. Full-screen artifacts own their internal responsive layout.
- **Shared spacing scale.** Prefer `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (24), and `xxl` (32). Native components also use optical and content-specific spacing: transcript blocks use 20pt, and settings rows use 20pt horizontal and 14pt vertical padding. Set stack spacing explicitly for the component.
- **Generous touch targets.** Target at least 44pt in both dimensions for custom buttons. Shared chip buttons keep a 32pt visual height inside a minimum 44pt target.
- **The composer lives at the bottom.** It is narrower and centered while empty and unfocused, then expands when active. Its resting width is 84% of the container; horizontal outer padding is 8pt at rest and 12pt when active. Attached services and artifacts sit in a strip above it.
- **Requests belong to the conversation.** Permission, choice, and service-control surfaces appear as transcript blocks. Service controls remain as inactive history after resolution; authentication and verification do not use a separate transient dock above the composer.

Settings pages use 20pt horizontal and 16pt vertical padding, with 32pt between sections and 8pt between a section header and its content.

## Elevation & Depth

Ox combines **tonal content surfaces with Liquid Glass controls and overlays**. Grouped pages place `surface` content on `background`; the chat canvas uses `chat-surface`. Navigation controls, the composer, composer chips, request surfaces, and toasts use regular glass, with interactive glass on applicable controls. Glass is a material, so its appearance depends on the content behind it. See Apple's [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

Prefer tone and spacing for ordinary content separation. Native settings groups and structured content can use dividers. The hold-to-talk overlay uses a subtle 1pt border and soft shadow; its selected actions also use an outline. These are component-specific treatments, not defaults for every card or input.

## Shapes

The shape language is **soft, broad, and continuous**. Strength comes from stable proportions rather than sharp corners.

- Chips and primary chip buttons use capsules with a 32pt visual height. Circular navigation controls use circles.
- Standalone settings rows and fields use the default glass-effect shape, a capsule, with an opaque `surface` fill. Grouped settings surfaces use `rounded.xl` (24pt).
- The composer, its draft attachment chips, and hold-to-talk overlay use `rounded.xl` (24pt).
- Permission, choice, and service-control surfaces use `rounded.lg` (18pt).
- Shoveler cards use `rounded.md` (12pt).
- Informational toasts use capsules; error toasts use `rounded.xl` (24pt).
- Smaller radii support nested thumbnails and service icons. Match the component's role rather than imposing one radius across an entire screen.

## Components

These descriptions capture native behavior. Interactive artifacts can reuse the palette, typography, and generic frontmatter defaults while keeping their own responsive layout.

- **Button (primary):** Shared chip buttons use `primary` fill, `on-primary` text, label typography, capsule shape, and 12pt horizontal padding. Onboarding uses a full-width capsule with a minimum 44pt height. Request actions use their own capsule sizing.
- **Button (secondary):** Shared unfilled chip buttons use `chip-on-background` fill and `on-surface` text. Settings action labels use a capsule with `primary` at 14% opacity and primary-colored text. Composer controls may use interactive glass.
- **Link:** Inline `primary` color on body type. Used when the agent is surfacing a navigable item from the page (a story title, an author, a comment thread).
- **List row:** Native lists use role-specific layouts. For artifact lists, start with `surface`, `body-md`, and 12px padding; settings use the explicit native metrics below.
- **Settings surface:** Opaque `surface` fill, body row typography, capsules for standalone rows and fields, and `rounded.xl` groups for multi-row content. Row padding is 20pt horizontal and 14pt vertical. Section headers, supporting copy, and dividers use the same 20pt horizontal inset.
- **Card / Shoveler:** The generic artifact card uses `surface`, `rounded.lg`, and 16px padding. Native Shoveler cards use `background`, `rounded.md`, and 12pt text-content padding. They scroll horizontally with 12pt spacing and widths from 160–280pt; a card can open one referenced artifact.
- **Input:** Use the containing native component's shape and material: settings fields use settings surfaces and chat entry uses the glass composer. The generic artifact input uses `surface`, a 12px radius, and 12px padding. Keep keyboard focus visible and preserve native editing behavior.
- **Composer:** Regular glass with a 24pt continuous radius, attachment control, text entry, and send, stop, or attachment-loading states. The strip above it exposes attached services, artifacts, and applicable prompt shortcuts.
- **Service chip:** A 32pt capsule with service identity and optional authentication status. Composer chips use interactive glass; the shared chip defaults to `surface-sunken` elsewhere. Signed-in or authorized services show a muted filled check; signed-out, unknown, or unavailable states show a hollow circle. Checking and signing in show a cellular-automaton loader. No icon appears when sign-in is not required. A tap opens service details. The current chip has no long-press menu; variants without auth status can expose a trailing remove button.
- **Service control:** An 18pt rounded glass transcript surface with 12pt padding, service identity, a short instruction, and an active sign-in, verification, or payment action. Only the pending interaction is actionable; older blocks retain their identity and instruction without an action. Verification and payment can show completion checkmarks while resolving; sign-in hides its action on success. The real service page opens in a separate native sheet when needed.
- **Interactive artifact:** A dedicated full-screen HTML canvas with only Ox's close control above it. The artifact owns its internal visual language, but should default to one phone-width column, native body type, generous targets, and warm accents.
- **Toast:** Regular glass, `on-surface` label text, and 14pt horizontal / 10pt vertical padding. Info uses a capsule and primary-colored check icon; errors use a 24pt rounded rectangle and error-colored warning icon. Info dismisses automatically after 1.8 seconds by default; errors stay until dismissed. Toasts can include an Open Settings action.

Pressed treatments vary by component: onboarding uses `primary-pressed`, shared chip buttons reduce fill opacity to 0.7, and `OxPressedSurfaceButtonStyle` reduces the whole label's opacity to 0.7. Interactive glass supplies native touch feedback. Preserve target geometry during presses; composer expansion and loading or completion transitions follow the component's explicit state.

## Do's and Don'ts

- **Do** use theme tokens: warm cream and brown in Ox, neutral surfaces in Light and Dark, and a distinct chat canvas.
- **Do** give primary emphasis a clear purpose. Avoid making adjacent controls compete for attention.
- **Do** prefer larger type and fewer items. The agent has license to drop content the user didn't ask for.
- **Do** use `on-surface` for text and `on-surface-muted` for metadata and disabled states.
- **Do** use tonal fills for content and glass for the native controls and overlays described here.
- **Don't** add decorative borders or shadows to every surface. Preserve purposeful dividers and the hold-to-talk treatments.
- **Do** choose shapes by component role and keep matching components consistent.
- **Do** support Dynamic Type and provide generous touch targets around compact visual controls.
- **Do** keep service pages behind the credential firewall during ordinary assistant work; present the real page only for explicit browsing, authentication, bot control, or payment review.
- **Don't** use SF Mono outside URLs, code, and debug surfaces — it cools the palette instantly.
