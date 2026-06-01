---
name: Souffleuse
description: Le mot juste, soufflé à voix basse — a printed-playbill design system for a private Mac writing assistant.
colors:
  sang-de-boeuf: "#8c2b21"
  sang-de-boeuf-deep: "#6f2018"
  ink: "#1a1613"
  ink-soft: "#463d33"
  ink-faint: "#5e5446"
  ghost: "#a99a82"
  paper: "#f3ead9"
  paper-deep: "#ece0c9"
  paper-edge: "#e3d5ba"
  paper-card: "#fbf5ea"
typography:
  display:
    fontFamily: "Bodoni Moda, Georgia, serif"
    fontSize: "clamp(2.7rem, 8.5vw, 6.4rem)"
    fontWeight: 700
    lineHeight: 0.96
    letterSpacing: "-0.005em"
  headline:
    fontFamily: "Bodoni Moda, Georgia, serif"
    fontSize: "clamp(2rem, 5vw, 3.4rem)"
    fontWeight: 700
    lineHeight: 1.04
    letterSpacing: "normal"
  title:
    fontFamily: "Bodoni Moda, Georgia, serif"
    fontSize: "1.45rem"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "normal"
  body:
    fontFamily: "Spectral, Georgia, serif"
    fontSize: "clamp(1rem, 0.95rem + 0.35vw, 1.12rem)"
    fontWeight: 400
    lineHeight: 1.66
    letterSpacing: "normal"
  label:
    fontFamily: "Bodoni Moda, Georgia, serif"
    fontSize: "0.72rem"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "0.28em"
rounded:
  hairline: "1px"
  paper: "2px"
spacing:
  measure: "64ch"
  gap-sm: "0.7rem"
  gap-md: "1rem"
  gap-lg: "1.6rem"
  section: "clamp(3.2rem, 8vw, 6rem)"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.hairline}"
    padding: "0.72rem 1.4rem"
    typography: "{typography.label}"
  button-primary-hover:
    backgroundColor: "{colors.sang-de-boeuf}"
    textColor: "{colors.paper}"
  button-primary-active:
    backgroundColor: "{colors.sang-de-boeuf-deep}"
    textColor: "{colors.paper}"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.hairline}"
    padding: "0.72rem 1.4rem"
  button-ghost-hover:
    backgroundColor: "transparent"
    textColor: "{colors.sang-de-boeuf}"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.ink-faint}"
    rounded: "{rounded.hairline}"
    padding: "0.2rem 0.55rem"
    typography: "{typography.label}"
  tab-selected:
    backgroundColor: "transparent"
    textColor: "{colors.sang-de-boeuf}"
  kbd:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.paper}"
    padding: "0.08rem 0.45rem"
---

# Design System: Souffleuse

## 1. Overview

**Creative North Star: "Le Trou du Souffleur"** (the prompter's box).

The whole interface is the nook at the edge of a stage from which a forgotten line is whispered, then nothing. Souffleuse is a private, on-device writing assistant for the Mac; the site has to make one idea land before it sells anything: a quiet voice slips you the right word and disappears. So the system never behaves like software showing off. It behaves like a well-printed theatre programme you were handed in the dark, paper you can almost feel, set in lead type, with one drop of sang-de-bœuf ink reserved for the moments that matter: the live cue, the action, the breath.

Density is low and deliberate. One dominant idea per fold, generous fluid spacing, long calm scroll. Type does the heavy lifting (two serifs, no sans, no mono), and the only ornaments are theatrical ones: programme filets, a *cul-de-lampe* fleuron, small-caps didascalies, "en trois actes". Depth is printed, not digital: sheets lift off the page on a hard, blurless offset shadow, the way a card sits proud of a poster, never the soft ambient glow of a SaaS dashboard.

This system explicitly rejects the cold/clinical AI tool (no dark terminal, neon, or "powered by AI" badge), the loud/salesy landing page (no pop-ups, urgency banners, exclamation-mark copy), and the cluttered feature-grid (no wall of identical icon cards). It is intimate, not promotional; it whispers, it never pitches.

**Key Characteristics:**
- Printed-playbill aesthetic: paper grain, hairline filets, small-caps labels, theatrical didascalies.
- Two serifs only (Bodoni Moda display + Spectral body). No sans, no mono.
- Sang-de-bœuf used as a rare signal, never as decoration.
- Letterpress depth: hard offset shadows, zero blur.
- Cut-paper corners (1–2px), never pill-rounded.
- Motion is the settling of ink: blur-to-sharp, decelerate, never bounce.

## 2. Colors

A warm printed-paper field of low-chroma neutrals, governed by a single deep oxblood accent. The warmth is committed identity, carried by ink and type, not by tint-by-default.

### Primary
- **Sang-de-Bœuf** (`#8c2b21`): the one voice. The whispered cue, the live dot on the "À vous" tab, every link hover and `:focus-visible` ring, the drop-cap lettrine, the selected tab and primary-button hover. It marks action and the breath, nothing else.
- **Sang-de-Bœuf Deep** (`#6f2018`): the pressed state. Primary button `:active` only.

### Neutral
- **Ink** (`#1a1613`): primary text, hairline filets, primary-button rest state, and the inverted dark surfaces (the `.feature--wide` key card, the "coulisses" privacy section).
- **Ink Soft** (`#463d33`): secondary prose, ledes, body copy inside sections, stage directions.
- **Ink Faint** (`#5e5446`): tertiary labels, captions, footer meta. Deliberately darkened from a paler value to clear WCAG AA on small text; hold this floor.
- **Ghost** (`#a99a82`): the pale ink of the *souffle* itself, the unaccepted whisper. Decorative / illustrative only. Never load-bearing text.
- **Paper** (`#f3ead9`): the body background, the page.
- **Paper Deep** (`#ece0c9`): the next surface up: manifesto band, footer, demo title bar, inline shortcode chips.
- **Paper Edge** (`#e3d5ba`): text and hairline borders *on* the dark ink surfaces.
- **Paper Card** (`#fbf5ea`): the brightest sheet, reserved for framed objects that sit proud of the page (the prompter's window, the pulse-card, the features panel).

### Named Rules
**The One Voice Rule.** Sang-de-bœuf is the only chromatic accent in the system and appears on a small fraction of any screen. Its rarity is the meaning: it is the whisper made visible. Never add a second hue to "balance" it.

**The Warm-Ink, Not Warm-Wash Rule.** Warmth comes from the ink ramp and the serifs, not from pushing the paper toward a brighter cream. The four paper steps are the whole background vocabulary; do not introduce new lighter tints.

## 3. Typography

**Display Font:** Bodoni Moda (with Georgia, serif fallback)
**Body Font:** Spectral (with Georgia, serif fallback)
**Label Font:** Bodoni Moda (small-caps / tracked uppercase)

**Character:** A Didone display (high-contrast, theatrical, programme-cover) set against a calm literary text serif. The pairing is a stage and its script: Bodoni is the marquee, Spectral is the line being read. No sans-serif and no monospace ever enter; their absence is the voice.

### Hierarchy
- **Display** (Bodoni Moda 700, `clamp(2.7rem, 8.5vw, 6.4rem)`, line-height 0.96, letter-spacing -0.005em): the hero title only. `text-wrap: balance`. A nested italic 500 sub-line in sang-de-bœuf carries the tagline.
- **Headline** (Bodoni Moda 700, `clamp(2rem, 5vw, 3.4rem)`, line-height 1.04): section titles (`.section-head h2`).
- **Title** (Bodoni Moda 700, ~1.4–1.45rem, line-height 1.1): feature, step, and vow headings (`h3`). FAQ questions use Bodoni 500 at 1.22rem.
- **Body** (Spectral 400, `clamp(1rem, 0.95rem + 0.35vw, 1.12rem)`, line-height 1.66): all prose. Hold the measure at 64ch (`--measure`); ledes cap near 50–60ch. Italic Spectral is the recurring voice for stage directions and codas.
- **Label** (Bodoni Moda 500, 0.72rem, letter-spacing 0.28em, UPPERCASE): the `.smallcaps` programme labels, app names, context lines, act markers.

### Named Rules
**The Two-Serif Rule.** Exactly two families: Bodoni Moda for display and labels, Spectral for prose. Introducing a sans or a mono is prohibited; it would read as a tech costume the brand refuses.

**The Didascalie Rule.** Italic Spectral is the system's stage-direction voice (eyebrows, captions, codas, system requirements). Set asides in italic body, not in a tracked uppercase eyebrow.

## 4. Elevation

Depth is printed, never digital. Surfaces are flat sheets of paper; the framed ones are lifted off the page by a single hard offset shadow with **zero blur**, the way a card sits proud of a letterpress poster. Soft, blurred ambient shadows (the SaaS drop-shadow) are forbidden; they would break the printed-object illusion instantly. A faint inset highlight along the top edge sells the paper's thickness.

### Shadow Vocabulary
- **Printed sheet** (`box-shadow: 0 1px 0 rgba(255,255,255,0.6) inset, 5px 7px 0 rgba(26,22,19,0.10)`): the prompter's window. Inset top highlight + hard offset cast.
- **Lifted card** (`box-shadow: 5px 6px 0 rgba(26,22,19,0.10)`): the pulse-card and other framed figures.
- **Pressed keycap** (`box-shadow: 1px 1px 0 rgba(26,22,19,0.25)`): `<kbd>` keys. A tiny offset that reads as a physical key.

### Named Rules
**The Letterpress Rule.** Every shadow in the system is a hard offset (`Xpx Ypx 0`) with a blur radius of exactly 0. If a shadow has blur, it is wrong. Depth is the cast of a sheet on the page, not a glow.

## 5. Components

For each component: a tactile, letterpress-physical feel governs. Edges are cut, not pilled; the accent appears only where there is action or a cue.

### Buttons
- **Shape:** near-square, 1px radius (`--rounded.hairline`); a cut corner, never a pill.
- **Primary:** ink fill, paper text, 1px ink border, Bodoni 500 with 0.04em tracking, padding `0.72rem 1.4rem`. Carries the Apple logo SVG inline before "Télécharger pour Mac".
- **Hover / Focus:** background and border shift to sang-de-bœuf over 0.22s ease; `:active` deepens to sang-de-bœuf-deep. `:focus-visible` draws a 2px sang-de-bœuf outline at 3px offset.
- **Ghost (`.btn--ghost`):** transparent fill, ink text; hover flips text and border to sang-de-bœuf with no fill. **Small (`.btn--small`):** tighter padding `0.5rem 1rem`, 0.85rem.

### Tabs (scene selector)
- **Style:** Bodoni 500 tracked uppercase, ink-faint at rest, transparent border. Selected tab takes sang-de-bœuf text + 1px sang-de-bœuf border.
- **State:** the live "À vous" tab carries a 5px sang-de-bœuf dot before its label (opacity 0.55 at rest, 1 when selected): the only "this is interactive" tell. Implemented as ARIA `role="tab"` with roving `tabindex`.

### Cards / Containers
- **Corner Style:** 2px (`--rounded.paper`). Framed objects only; most sections are open, divided by hairline filets rather than boxed.
- **Background:** paper-card (`#fbf5ea`) for lifted figures; ink (`#1a1613`) for the inverted key card and the coulisses vows.
- **Shadow Strategy:** the Letterpress Rule (Section 4). Hard offset, zero blur.
- **Border:** 1px ink filet, or 1px ink at 0.4 alpha for interior grid dividers.
- **Internal Padding:** ~`1.7rem 1.6rem`.
- **Note:** the features block is a single bordered grid, NOT a set of free-floating identical cards; a full-width inverted `.feature--wide` card breaks the two-column rhythm and carries the key message.

### Inputs / Fields (the "À vous" try-line)
- **Style:** an inline `contenteditable` span on the same baseline as the whispered ghost span; no box, no chrome. Caret color is sang-de-bœuf. Empty state shows an italic ink-faint placeholder via `::before`.
- **Focus:** no border; the breathing sang-de-bœuf caret carries focus. Keyboard: Tab takes the suggestion, ↓ cycles, Esc dismisses; an `aria-live` status narrates changes.

### FAQ (`details`/`summary`)
- **Style:** open accordion divided by hairline filets, no boxes. Bodoni 500 question at 1.22rem. The default disclosure marker is removed; a sang-de-bœuf "+" sits at the right and rotates 45° to "×" when open.

### Signature Component: Le Trou du Souffleur (demo window)
The hero's prompter window. A programme-bar header (fleuron seal + tracked app name + scene tabs) replaces the SaaS traffic-light title bar. Inside, typed text in ink and the *souffle* in pale-ghost italic share one baseline, with a breathing sang-de-bœuf caret between them. Taking the line (Tab/click) drops the italic, recolors to ink, and flashes a brief warm highlight: the exact gesture the app performs. Min-height is reserved so scenes of different lengths don't jump.

## 6. Do's and Don'ts

### Do:
- **Do** keep sang-de-bœuf (`#8c2b21`) rare and meaningful: action, the live cue, focus, the whisper. The One Voice Rule.
- **Do** convey depth with hard offset shadows (`Xpx Ypx 0`, zero blur) and a faint inset top highlight. The Letterpress Rule.
- **Do** set every heading and label in Bodoni Moda and all prose in Spectral. Italic Spectral for stage directions. The Two-Serif and Didascalie Rules.
- **Do** divide content with hairline filets and open composition; reserve the 2px-cornered paper-card for figures that genuinely sit proud of the page.
- **Do** keep prose to the 64ch measure, body text on ink-soft or darker, and hold ink-faint as the small-text AA floor (≥4.5:1).
- **Do** animate as settling ink: blur-to-sharp with a decelerating cubic-bezier, and ship a `prefers-reduced-motion: reduce` fallback for every motion.

### Don't:
- **Don't** build a cold/clinical AI tool look: no dark-terminal-neon, no "powered by AI" badge, no robotic chrome. The tech stays invisible.
- **Don't** go loud or salesy: no pop-ups, urgency banners, exclamation-mark copy, or repeated aggressive CTAs. It whispers; it never pitches.
- **Don't** clutter: no wall of identical icon-cards, no competing focal points. One dominant idea per fold.
- **Don't** add a sans-serif or monospace, or a second accent hue. Two serifs, one voice.
- **Don't** use soft blurred ambient shadows, glassmorphism, gradient text, or pill-rounded corners. If a shadow has blur, it is wrong.
- **Don't** push the paper toward a brighter cream to feel "warmer", or let ghost (`#a99a82`) carry real text. Warmth is in the ink and the type.
- **Don't** write with em dashes; use commas, colons, or parentheses, matching the existing French copy.
