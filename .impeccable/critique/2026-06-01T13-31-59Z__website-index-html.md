---
target: website/index.html
total_score: 36
p0_count: 0
p1_count: 2
timestamp: 2026-06-01T13-31-59Z
slug: website-index-html
---
# Re-Critique — website/index.html (Souffleuse) — post-fix round

## Design Health Score: 36/40 (Excellent), up from 32/40

| # | Heuristic | Score | Note |
|---|-----------|-------|------|
| 1 | Visibility of system status | 4 | tabs aria-selected, live count, breathing caret, is-took flash; mascotte narrates section. |
| 2 | Match system/real world | 4 | theatre metaphor coherent, French-first, lay M1/Intel explanation. |
| 3 | User control & freedom | 4 | Esc/drop everywhere, real download, Tab-trap gated. |
| 4 | Consistency & standards | 4 | textbook tablist ARIA; letterpress applied uniformly. |
| 5 | Error prevention | 3 | 180-char cap + paste truncation + Enter-suppress good; contenteditable IME edge. |
| 6 | Recognition over recall | 4 | kbd hints visible, context label shown. |
| 7 | Flexibility & efficiency | 3 | click/key/ghost all work; demo desktop-keyboard-centric, muted on touch. |
| 8 | Aesthetic & minimalist | 4 | restrained, one accent, 64ch measure, no jump. |
| 9 | Help with errors | 3 | brochure; try-demo silent on unmatched short input. |
| 10 | Help & documentation | 3 | strong FAQ; pricing answer dead-ends at the DMG. |

## Anti-Patterns Verdict
Authored, not generated. Conceit sustained from <title> to favicon theme-color to CSS comments. Privacy argued not asserted. Detector: exit 0, clean (em-dash finding resolved). No slop.

## Fixes verified (9/9 landed)
1. Download CTA -> ./Souffleuse.dmg + download (topbar/hero/finale) — PASS.
2. .sr-only defined + used on #demo-desc and #demo-live — PASS.
3. Tab-capture gated on figure.contains(activeElement) — PASS (Esc still keys off hover; harmless).
4. Dead .acts CSS deleted — PASS.
5. overflow-wrap + max-height + 180-char cap (input+paste) — PASS.
6. Em dashes removed from visible copy — PASS (verified; only CSS/JS comments remain).
7. Bar wraps <560px; coarse-pointer >=44px targets — PASS.
8. Topbar blur removed (solid --paper) — PASS.
9. souffle-respire infinite -> 4 cycles — PASS.

## New additions
- Mascotte (context-aware whisper per section): KEEP. On-brand, elegant, a11y-clean (aria-hidden, pointer-events none, reduced-motion handled). Tune: overlap risk where her fixed box + z-index:5 can paint the red whisper over body copy on mid-wide viewports; consider lowering z-index or constraining width/breakpoint.
- OG/Twitter meta + og.png (1200x630 paper+Bodoni card) + favicon set + canonical + theme-color: complete and correct. Absolute URLs present.

## Remaining issues
- [P1] OG/canonical/twitter URLs hardcode the current vercel.app production alias; update when a custom domain is added (correct for now).
- [P1] Pricing FAQ points to "la page de téléchargement" which is just the DMG, not a pricing page — broken expectation at a trust moment. State price/free-tier inline or link a real anchor.
- [P2] Mascotte overlap window on mid-wide viewports (z-index above content).
- [P2] contenteditable capInput() can fight IME composition (accents); guard with isComposing/compositionend.
- [P3] Esc keys off hover not just focus; minor.

## Questions
1. Converting the mobile visitor or only the at-their-Mac user? Where's the keyboard-free way to feel the souffle?
2. Is the em-dash asceticism hiding that the product proudly IS a (local) language model?
3. Does the per-section whispering mascotte enrich the copy or quietly upstage the headlines?
