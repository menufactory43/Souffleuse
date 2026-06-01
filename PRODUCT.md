# Product

## Register

brand

> Brand-primary. The marketing site (`website/index.html`) is the surface impeccable
> optimizes by default. In-app UI (ghost overlay, HUD, Preferences) shares the same
> identity and may be worked on as a secondary product-register surface; when a task
> targets app UI, override to `product` for that task.

## Users

Mac users who write all day in someone else's app: Mail, Messages, Notes, a browser
text field, a chat client. Writers, freelancers, support agents, anyone who hesitates
mid-sentence and wants the right word without breaking flow. They are privacy-aware
(the on-device promise matters to them) and have taste: a generic SaaS pitch reads as
noise. Their context when they meet the site is evaluative and skeptical — "another AI
writing tool?" — so the job of the page is to *dissolve that skepticism by showing the
thing working*, then earn the download.

## Product Purpose

Souffleuse is a 100% on-device writing assistant for macOS. It slips the right word
under your caret as a faint *ghost text* when you hesitate, anywhere you type; you take
it with Tab or let it pass with Esc. Beyond the ghost it also does translation, tone
re-reading, and keeps a private usage ledger. Nothing leaves the Mac.

The site exists to make a single idea land: **the whispered prompt**. Success is a
visitor who *gets it* — who understands the souffleuse-in-the-wings concept from the
live demo before they read a feature list — and then trusts the privacy promise enough
to download. Concept comprehension is the primary outcome; the download is what
comprehension plus trust produces.

## Brand Personality

Three words: **discrète, lettrée, théâtrale** (discreet, literate, theatrical).

The throughline is the *souffleuse* — the prompter crouched in the wings of a theatre
who whispers the forgotten line so the actor never falters, then vanishes. Every
section is staged inside that conceit: the page is a printed programme (paper, filets,
didascalies, "en trois actes"), the copy is hushed and literary French, the tone is
intimate rather than promotional. It should feel like being let in on something quiet
and well-made, not sold to.

Emotional goals: calm confidence, intimacy, earned trust, a restrained note of delight.
Voice: French-first, lettered, understated, present and warm. It whispers; it never
pitches.

## Anti-references

- **Cold / clinical AI tool.** No dark-terminal-neon, no "powered by AI" badges, no
  robotic voice. Souffleuse is human and intimate; the tech is invisible on purpose.
- **Loud / salesy.** No pop-ups, urgency banners, exclamation-mark copy, or aggressive
  repeated CTAs. Anything that raises its voice breaks the hushed theatrical register.
- **Cluttered / busy.** No wall-of-features, no competing focal points, no section
  sprawl. One dominant idea per fold; composed and quiet beats dense.
- **Generic SaaS landing** (implied by the above): gradient hero, identical feature-card
  grid, hero-metric template, buzzword copy. The modal AI-startup page is the failure.

## Design Principles

1. **Souffler, pas crier** — whisper, don't shout. The interface practices what the
   product preaches: it stays quiet, gets out of the way, and never competes with its
   own content for attention.
2. **Montrer le souffle** — show, don't tell. The live, interactive demo proves the
   concept faster and more honestly than any sentence of copy. Comprehension is staged,
   not asserted.
3. **La coulisse est privée** — privacy is felt, not claimed. Make the on-device promise
   tangible (the "coulisses" section, the system-req footer, the absence of any network
   tell) so trust is earned rather than badge-stamped.
4. **Le théâtre est cohérent** — the prompter conceit governs every section as a
   genuine throughline (programme, actes, didascalies, souffle), never as decoration
   bolted onto a generic layout. Consistency of *voice* over consistency of treatment.
5. **Lettré, jamais lourd** — literary French restraint. Every word earns its place; no
   marketing buzzwords, no em dashes, no aphoristic filler. Precision is the luxury.

## Accessibility & Inclusion

Target: **WCAG 2.2 AA.** Body text ≥4.5:1 (the token comments already note darkening
`--ink-faint` to pass AA on small text; hold that line), large text ≥3:1. Full keyboard
navigation including the hero demo's tab/roving-tabindex pattern and the "À vous"
contenteditable try-field. Every animation needs a `prefers-reduced-motion: reduce`
alternative (crossfade or instant). Screen-reader narration of the live ghost demo via
`aria-live` / `sr-only` description must stay meaningful as scenes change. French-first
content with `lang="fr"`; any embedded foreign-language strings (translation demo) get
their own `lang`. Focus-visible states stay clearly drawn in the sang-de-boeuf accent.
