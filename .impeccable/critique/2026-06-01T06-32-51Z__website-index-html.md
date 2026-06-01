---
target: website/index.html
total_score: 32
p0_count: 1
p1_count: 2
timestamp: 2026-06-01T06-32-51Z
slug: website-index-html
---
# Design Critique — website/index.html (Souffleuse, "Le Livret")

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Demo status excellent (breathing caret, armed-state kbd highlight, aria-live count); but the documented `.acts` I·II·III progress indicator is styled and never rendered. |
| 2 | Match System / Real World | 4 | Mac-native vocabulary, French-first, theatre metaphor coherent throughout. |
| 3 | User Control and Freedom | 3 | Demo is reversible (Esc/↓/click); scripted demo has no pause; global smooth-scroll (disabled under reduced-motion). |
| 4 | Consistency and Standards | 3 | Strong token discipline; `.sr-only` used but undefined (two divergent SR-hiding strategies); Tab key hijacked when demo armed. |
| 5 | Error Prevention | 3 | contenteditable sanitizes paste to single-line plaintext, blocks Enter; but global Tab-capture can eat focus traversal. |
| 6 | Recognition Rather Than Recall | 4 | Every shortcut shown inline as a `<kbd>`; nothing to memorize. |
| 7 | Flexibility and Efficiency | 3 | Click/key/button all drive the same action; 4 tabs + "À vous" is a lot of demo surface for a first read. |
| 8 | Aesthetic and Minimalist Design | 4 | Strongest axis: single accent, generous measure, no clutter. |
| 9 | Error Recovery | 2 | Demo recovers fine, but the terminal download action dead-ends (`href="#"`) with no destination to recover to. |
| 10 | Help and Documentation | 3 | FAQ answers real objections; no system-req reinforcement at the CTA itself (only footer). |
| **Total** | | **32/40** | **Good — shipping-grade, dragged down by the unwired CTA and dead `.acts` indicator.** |

## Anti-Patterns Verdict

**Does this look AI-generated? No — it reads as authored.** The theatrical conceit is load-bearing (drives IA, copy, and the signature animation), the "souffle" motion is a specific metaphor-to-easing mapping rather than a fade-in preset, and there's craft an LLM rarely volunteers (a cascade-specificity fix comment, `--ink-faint` darkened "pour passer AA", localized aria-live easter-egg copy). The committed warm-paper + Bodoni/Spectral + sang-de-bœuf identity is deliberate brand, correctly NOT flagged as AI-cream slop. The one generic tell is structural: the section order is the canonical SaaS skeleton (hero → manifesto → feature grid → privacy → 3 steps → FAQ → CTA), but the theatrical relabeling earns it back.

**Deterministic scan:** detector exit code 2, **1 rule fired — `em-dash-overuse` ("14 em-dashes in body text")**. This is a REAL issue, not a false positive: DESIGN.md explicitly bans em dashes ("use commas, colons, or parentheses"). Caveat: the 14 count is over-stated — it includes CSS comments, the `<title>`, and JS string literals; true count in rendered visible prose is lower (e.g. lines 416, 1058, 1076, footer). The palette/serif/small-caps committed-identity traps did NOT fire (clean). No contrast, alt-text, or overflow findings.

**Visual overlays:** none — no browser-automation tool in this environment, so no live overlay was produced. Findings are from source review + the CLI detector.

## Overall Impression

This is a genuinely well-made page with a clear point of view, let down by one fact: **on a page whose entire job is a download, every download path is unwired.** The craft, the privacy framing, and the signature animation are all strong enough to convert a skeptic — and then the finale button goes to `href="#"`. The single biggest opportunity is to make the terminal action real (or honestly pre-launch), because the peak-end of the emotional arc currently lands on a dead click.

## What's Working

1. **The "souffle" signature motion is metaphor-perfect and clean** (CSS 413–434): word-by-word condense-from-blur, drift from stage-left, decelerate with no bounce, then a breathing "alive" state — it IS the product idea, animated. It plays once then quiets, respecting attention.
2. **Privacy framed as architectural impossibility, not policy** (1208–1214, 1239–1242): "il n'y a tout simplement pas de porte de sortie" earns trust the way a skeptic respects — far stronger than a checklist.
3. **Accessibility is authored, not bolted on**: skip link, a `prefers-reduced-motion` block that neutralizes every custom animation, a full ARIA tablist with roving tabindex, an SR-only description of the decorative demo, and an AA-darkened ink token.

## Priority Issues

**[P0] Download CTA dead-ends.** The finale download button (line 1372) is `href="#"`; the topbar "Télécharger" (1020) and hero CTA (1045) both point at `#telecharger`, which is the finale *section* — not a file/store. So every download path leads to a CTA that itself dead-ends.
- *Why it matters:* this is the conversion event; the page can be a 10/10 and convert near zero. It also poisons the peak-end moment and quietly erodes the trust just built.
- *Fix:* wire to the real artifact (DMG / App Store / TestFlight). If pre-launch, make it honest — "Le rideau se lève bientôt, laissez votre adresse" email capture — instead of a fake download affordance.

**[P1] The concept gesture is undelivered on touch/mobile.** The demo's interaction model keys off `mouseenter`/`focusin`; there's no touch/pointer arming. The Tab/Esc/↓ `<kbd>` hints describe keys a phone doesn't have, and although the take/cycle/drop buttons are tappable, they're labeled as keyboard keys so a mobile user won't know to tap them. Demo tabs and hint buttons are also below the 44px touch target minimum.
- *Why it matters:* "grasp the concept" is the page's stated primary outcome, and the signature gesture is how it lands — gating it behind hover + keyboard leaves the core idea undelivered to mobile visitors.
- *Fix:* arm on `touchstart`/pointer, swap kbd-labeled hints for tappable button affordances on touch, raise tap targets to ≥44px, and ensure the ghost suggestion isn't occluded by the mobile keyboard.

**[P1] `.sr-only` is used but never defined → visible SR text.** `#demo-live` (1097, `role="status" aria-live="polite"`) carries `class="sr-only"`, but `.sr-only` has no CSS definition (verified). Unlike `#demo-desc` (1084), which clips via inline style, this element is not hidden — so when the easter egg sets its text ("Conseil non sollicité accepté.") it renders on-screen in the most-interacted panel.
- *Why it matters:* a stray visible string in the "À vous" panel looks like a bug, exactly where users are poking.
- *Fix:* add the standard `.sr-only { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; }` and reuse it for `#demo-desc` instead of the inline duplicate.

**[P2] Global Tab-capture can eat keyboard focus traversal.** The document-level keydown (1651–1660) `preventDefault()`s plain Tab whenever the demo is `pending && armed`, and `armed` is set on mouse-hover. A sighted keyboard user who has hovered the demo while tabbing the page has Tab silently consumed — a WCAG 2.1.2 (no keyboard trap) risk.
- *Fix:* gate the capture on `figure.contains(document.activeElement)`, not on hover-derived `armed`.

**[P2] The documented act-progress indicator never renders (dead CSS).** `.acts` / `.acts span.on` are fully styled (928–954) but there is no `.acts` element in the DOM and no JS to drive it (verified). The page's one cross-scroll wayfinding cue is absent, and shipping dead CSS is a maintenance smell.
- *Fix:* decide — implement it (a small IntersectionObserver toggling `.on` would genuinely help the long single-scroll) or delete the rules to keep the stylesheet honest.

## Persona Red Flags

**Jordan (confused first-timer):** the scripted demo autoplays once then freezes (`played[]`); scroll past and back and Jordan sees a static frozen sentence with no motion, so the "ghost suggestion" idea may never land. Replay is only via clicking a tab. The hero CTA "Voir comment elle souffle →" also jumps to the demo directly beneath it, which can feel like it "did nothing."

**Riley (stress-tester, "À vous"):** the contenteditable has `white-space:pre-wrap` but no `overflow`/`max-height` — pasting a long paragraph wraps and blows out the `min-height:12.5rem` stage, pushing layout (real overflow risk). `document.execCommand("insertText")` (1817) is deprecated and may silently no-op in some browsers. Re-clicking a tab `forceReplay`s the full type-out, so hammering tabs gives a stuttery re-typing show.

**Casey (distracted, one-handed mobile):** the whole interaction is hover/keyboard (see P1). On touch the payoff gesture and the kbd hints don't apply, and sub-44px targets miss thumbs.

**Privacy-skeptical Mac power user ("another AI writing tool"):** the narrative earns trust ("pas de porte de sortie") but every claim is asserted, not substantiated — no "auditable / no network entitlement", no named on-device model, no "block us in Little Snitch and watch it still work" verification path. The honest "connects once at install" admission (1274, 1339) is the credible seam to lean into. For this persona especially, an `href="#"` download on a privacy product reads as vaporware.

## Minor Observations

- `backdrop-filter: blur(2px)` on the sticky topbar (138) is the one place blur appears, against the committed "zero blur / hard offset shadows" letterpress rule. It's on chrome, not content, but it's a literal invariant violation — consider a solid `--paper` topbar.
- Em dashes in visible French copy (416, 1058, 1076, footer) violate DESIGN.md's own ban — easy copy fix.
- "Cinq rôles" feature grid (5 cards) and the 5-link topnav both exceed the ≤4 chunking guideline; minor scan cost, the copy leans into "cinq."
- The `souffle-respire` breathing loop runs `infinite`; a perpetually pulsing hero element is a mild attention/repaint tax (disabled under reduced-motion). Consider stopping after N cycles.

## Questions to Consider

1. If the download can't be wired yet, why pretend it can? Would an honest "le rideau se lève bientôt" email capture convert better than a fake button — turning the P0 into a pre-launch asset, fully in character?
2. The demo proves the gesture but not the intelligence (scripted scenes + regex "À vous"). Would openly owning the artifice ("ceci est une mise en scène — la vraie Souffleuse pense sur votre Mac") build more trust with skeptics than hiding it?
3. For a privacy product, assertion is the weakest currency. Could a verifiable "block us and watch it still work" dare be the single most converting addition?
4. The signature gesture only fires once and only on desktop. What's the mobile version of "watching the word take the ink"?
