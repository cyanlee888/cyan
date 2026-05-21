---
version: alpha
name: Dino English
description: V1.1.0 onboarding and Class — forest classroom, live AI teacher
colors:
  forest-deep: "#143D2A"
  forest-mid: "#2D6B45"
  forest-light: "#A8E6CF"
  forest-mist: "#D4F8EC"
  surface: "#FFFBF8"
  surface-elevated: "#FFFFFF"
  ink: "#1A2420"
  ink-muted: "#4A5F54"
  accent-live: "#EA6C25"
  accent-glow: "#FFE8D6"
  border: "#C5DDD2"
typography:
  display:
    fontFamily: Sora
    fontWeight: 600
  body:
    fontFamily: "DM Sans"
    fontSize: 1rem
  label:
    fontFamily: "DM Sans"
    fontSize: 0.8125rem
    fontWeight: 600
rounded:
  sm: 12px
  md: 18px
  lg: 24px
  pill: 9999px
spacing:
  xs: 8px
  sm: 12px
  md: 16px
  lg: 24px
  xl: 32px
components:
  button-primary:
    backgroundColor: "{colors.forest-mid}"
    textColor: "#FFFFFF"
    rounded: "{rounded.pill}"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.forest-mid}"
    rounded: "{rounded.pill}"
  option-card:
    backgroundColor: "{colors.surface-elevated}"
    borderColor: "{colors.border}"
    rounded: "{rounded.md}"
---

## Overview

Dino English V1.1.0 presents a **forest classroom**: trustworthy, warm, slightly playful without infantilizing mixed-age learners. Pre-login flows are **portrait** and editorial; in-app Class is **landscape** and immersive.

## Tone

- **Live class first** — orange accent only for “live / speak / CTA” moments.
- **No emoji UI** — use SVG illustration slots instead.
- **Generous whitespace** on question screens; progress always visible.

## Colors

| Token | Use |
|-------|-----|
| `forest-deep` | Toast, dark overlays, progress text emphasis |
| `forest-mid` | Primary buttons, selected option border |
| `forest-light` / `forest-mist` | Hero backgrounds, chips |
| `accent-live` | Live badge, primary CTA gradient accent |
| `surface` | Page background |

## Typography

- **Sora** — headlines, logo wordmark feel.
- **DM Sans** — body, options, hints.

## Illustration slots (portrait)

| Screen | Slot ID | Subject |
|--------|---------|---------|
| Welcome | `illo-welcome` | Dino + AI teacher silhouette, forest canopy, “LIVE” pill |
| Purpose | `illo-purpose` | Lesson path nodes + clipboard |
| Value (L) | `illo-value` | Classroom frame, microphone, dialogue |
| Login | `illo-login` | Compact brand mark, no full hero |

## Motion

- Screen enter: 280ms fade + 12px rise.
- Option select: 150ms scale + border color.
- Carousel: 4s crossfade on welcome hero.
