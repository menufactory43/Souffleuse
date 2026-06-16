---
phase: quick-260616-eoy
plan: 01
subsystem: SouffleuseOverlay / SouffleuseAppDelegate
tags: [ghost-wrap, overlay, geometry, regression]
dependency-graph:
  requires: []
  provides: [ghost-wrap-multi-ligne]
  affects: [SouffleuseOverlay, SouffleuseAppDelegate]
tech-stack:
  added: [NSMutableParagraphStyle.firstLineHeadIndent, NSAttributedString, boundingRect wrap]
  patterns: [static-pure-helper, frameForShow-routing, TDD-red-green]
key-files:
  created: []
  modified:
    - Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift
    - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
    - Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift
decisions:
  - "WRAP à la ligne suivante retenu (pas de troncature ni de masquage) — parité comportement texte tapé"
  - "frameForShow helper pur exposé (public) pour testabilité directe sans instancier NSPanel"
  - "label.maximumNumberOfLines restauré à 1 dans le chemin fallback pour préserver le bottom-anchored Chromium/Intercom"
metrics:
  duration: "~9 minutes"
  completed: "2026-06-16T08:47:00Z"
  tasks: 2
  files: 3
---

# Phase quick-260616-eoy Plan 01: Ghost inline wrap multi-ligne (débordement bord droit) Summary

## One-liner

Rendu wrap multi-ligne du souffle inline via `isUsableElementRect` + `wrapFrame` + `frameForShow`, branché sur les 5 sites `overlay.show(...)` inline, avec repli pixel-identique sur le single-line bottom-anchored quand `fieldRect` est absent ou aberrant.

## What was built

### Task 1 — Prédicat + frame wrap (static/pur) + tests géométrie

Deux nouvelles méthodes statiques pures dans `OverlayWindow.swift` :

**`isUsableElementRect(_ rect: CGRect, caretX: CGFloat) -> Bool`**
Garde-fous calqués sur `isUsableWordRect` mais axés largeur de champ : `width >= 2`, `width < 4000`, origines finies, ET `caretX` dans `[minX - 1, maxX]`. Évite d'ancrer le wrap sur un frame de champ absent/aberrant (Chromium/Electron) ou sur un champ qui n'est pas celui du caret.

**`wrapFrame(forGhostAfterCaret:fieldRect:text:font:) -> (frame:CGRect, firstLineIndent:CGFloat)`**
- `firstLineIndent = max(0, caret.origin.x - fieldRect.minX)` — la 1re ligne part du caret.
- Mesure de la hauteur via `NSMutableParagraphStyle` (`firstLineHeadIndent`, `byWordWrapping`) + `boundingRect(.usesLineFragmentOrigin, .usesFontLeading)`.
- `width = ceil(fieldRect.width)` ; `appKitX = fieldRect.minX`.
- TOP-anchored sur la ligne du caret : `appKitY = primaryHeight - caret.origin.y - height`.

8 nouveaux `@Test` couvrant : prédicat × 4 (accepte sain, rejette zéro/étroit, rejette aberrant, rejette caret hors champ) + géométrie wrap × 4 (width, firstLineIndent, origine, hauteur multi-ligne).

### Task 2 — Branchement dans show() + threading aux 5 sites + tests régression

**`frameForShow(caret:fieldRect:text:font:) -> (frame, wrap, firstLineIndent)`** (public, pur)
Route vers `wrapFrame` si `fieldRect` est non-nil et passe `isUsableElementRect`, sinon retourne `appKitFrame(...)` inchangé avec `wrap=false`.

**`show(text:at:hostText:caretIndex:hostFont:fieldRect:CGRect?=nil)`**
- Forwarder simple `show(text:at:)` mis à jour pour passer `fieldRect: nil`.
- Chemin WRAP : `label.maximumNumberOfLines = 0`, `label.lineBreakMode = .byWordWrapping`, `label.attributedStringValue` avec `NSMutableParagraphStyle`.
- Chemin SINGLE-LINE (fallback) : restaure `maximumNumberOfLines = 1` + `lineBreakMode = .byTruncatingTail`, `label.stringValue = text` — comportement bottom-anchored Chromium/Intercom préservé au pixel près.
- `showPill` non touché (mid-line pill, hors scope — commenté).

**5 sites inline dans `SouffleuseAppDelegate.swift`** (lignes 1991, 2134, 2153, 2183, 2429) : ajout de `fieldRect: snap.elementRect`. Les 3 sites `overlay.showPill(...)` (lignes 4094, 4113, 4185) non modifiés.

3 tests régression via `frameForShow` : nil → pixel-identique à `appKitFrame`, court → single ligne, long → multi-ligne.

## Verification Results

- `swift build` : Build complete (0 errors)
- `swift test` : 972 tests in 85 suites — ALL PASSED
- `audit.sh` : AUDIT PASSED (no print/NSLog, no user-text interpolation, whitelisted fields)
- Les 5 sites inline passent `fieldRect: snap.elementRect` ; `showPill` non modifié.

## Commits

| Hash | Message |
|------|---------|
| ff7ca34 | feat(260616-eoy-01): add isUsableElementRect + wrapFrame statics + geometry tests |
| b414507 | feat(260616-eoy-01): wire wrap path in show() + thread fieldRect to 5 inline sites |

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None.

## Threat Flags

None. Les nouvelles méthodes sont des helpers géométriques purs sans accès réseau ni surface AX nouvelle.

## Self-Check: PASSED

- `OverlayWindow.swift` : contient `isUsableElementRect`, `wrapFrame`, `frameForShow` — FOUND
- `SouffleuseTests.swift` : contient `overlayIsUsableElementRect*`, `overlayWrapFrame*`, `overlayFrameForShow*` — FOUND
- `SouffleuseAppDelegate.swift` : 5 occurrences de `fieldRect: snap.elementRect` aux lignes 1991, 2134, 2153, 2183, 2429 — FOUND
- Commits ff7ca34 et b414507 — FOUND
