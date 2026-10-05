# DESIGN.md — Planet Mini App

> Design-system contract for `app-tg/`. Every token used in code traces back to this file.
> **Direction:** "On-chain ledger / technical terminal" — a monochrome, editorial-print
> system inspired by the *runtime tokens extracted from aptoslabs.com* (`clone-from-url`),
> recombined for Planet's own product and content. No Aptos fonts/logos/copy are copied.

## 0. Research Log

- **Live-URL reference:** aptoslabs.com, read with `getComputedStyle` in a real browser.
  Extracted: body `Zagma` 400 `#0F0F0F` on `#FFFFFF`; headings `Zagma Wide` 700,
  letter-spacing −0.57px; links/buttons `Zagma Expanded` 14.2px, tracking **+2.13px**,
  `border-radius: 0`; mono **`DM Mono`** used on 293 elements; hairline `1px` rules, sharp
  corners, numbered sections, `[ bracketed ]` labels, `¬` markers.
- **Substitutions** (proprietary type replaced, per anti-pattern rule): `Zagma*` → **Space
  Grotesk** (400/500/700). **`DM Mono` kept verbatim** (open Google font — the reference's own mono).
- **Layer A taste:** `minimalist-skill` lane — editorial, high-contrast, restrained.
- **Skip note:** no lazyweb/imagen lane — a concrete live URL was supplied, which *is* the contract.

## 1. Palette (monochrome + one signal)

| Token | Light | Dark | Use |
|---|---|---|---|
| `--paper` | `#FFFFFF` | `#0F0F0F` | surface |
| `--ink` | `#0F0F0F` | `#F5F5F5` | text, rules, fills |
| `--muted` | `#6B6B6B` | `#9A9A9A` | secondary text |
| `--hair` | `rgba(15,15,15,.14)` | `rgba(245,245,245,.16)` | 1px rules |
| `--hair-strong` | `rgba(15,15,15,.34)` | `rgba(245,245,245,.36)` | emphasis rules |
| `--signal` | `#C2401C` | `#E8663F` | frozen / error only |

No gradient, no accent hue. State is carried by **ink weight + glyph (▲▼)** and the single
`--signal` rust for faults. This is intentional: the reference is monochrome.

## 2. Typography

| Role | Family | Size / weight / tracking |
|---|---|---|
| Wordmark | Space Grotesk | 15px / 700 / `.16em` uppercase |
| Section label `[ 01 ] …` | DM Mono | 11px / 500 / `.18em` uppercase |
| Body | Space Grotesk | 14px / 400 / normal |
| Data numeral (hero) | DM Mono | 48px / 500 / tabular |
| Data numeral (cell) | DM Mono | 26px / 500 / tabular |
| Table / captions | DM Mono | 12–13px / 400 / tabular |

Loaded in `index.html`: Space Grotesk (400/500/700) + DM Mono (400/500). Never fall back to Inter.

## 3. Spacing & geometry

Scale: `4 · 8 · 12 · 16 · 24 · 32 · 48 · 64`. **`--radius: 0`** (sharp corners, as extracted).
Every separation is a `1px` hairline; density comes from rules, not cards/shadows. No box-shadow.

## 4. Motion

Micro only, meaning-bound: hover/focus ink-invert on controls, a `120ms ease` colour/border
transition, and one **signature moment** — a blinking `▍` caret after the hero PPI numeral.
`prefers-reduced-motion` disables the blink.

## 5. Primitives (states required)

| Primitive | Default | Hover / Focus | Disabled |
|---|---|---|---|
| `Button` (`.btn`) | ink fill, paper text, 0 radius | invert (paper/ink), 1px ink ring | 40% opacity, hair border |
| `Field` (`input`) | transparent, 1px `--hair` | 1px `--ink`; focus adds inset ink stroke | 40% opacity |
| `Cell` (`.cell`) | hairline top+bottom, mono label + mono numeral | — | muted |
| `SecHead` (`.sec-head`) | `[ 0N ] LABEL ¬` + flex hairline | — | — |
| `Tag` (`.drift`) | mono ▲/▼; up = ink, down = `--signal` | — | — |
| `Badge` (`.badge`) | `ok` = hair cell; `frozen` = `--signal` border/text | — | — |

Responsive: single column ≤ 640px; the hero numeral drops 48→36px. Min body width 320.

## 6. Accessibility

Ink-on-paper contrast ≥ 19:1 (AAA). Focus is always visible (1px ink ring, never removed).
Caret blink honours reduced-motion. All numerals tabular for stable columns.

## 7. Accepted debt

- No dark-mode toggle in-UI yet — honours `prefers-color-scheme` only.
- Telegram theme params not wired (`ThemeParams`) — system scheme is used instead.
