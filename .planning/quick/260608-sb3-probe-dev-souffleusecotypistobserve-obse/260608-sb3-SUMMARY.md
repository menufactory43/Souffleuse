---
phase: quick-260608-sb3
plan: 01
subsystem: probes-dev
tags: [ax, observability, cotypist, dev-tool, reverse-engineering]
requires: [SouffleuseAX, SouffleuseContext]
provides: [SouffleuseCotypistObserve]
affects: [Package.swift]
tech-stack:
  added: []
  patterns: [raw-ax-walking, cgevent-synthetic-keys, jsonl-output, axuielementcreateapplication]
key-files:
  created:
    - Souffleuse/Sources/SouffleuseCotypistObserve/main.swift
  modified:
    - Souffleuse/Package.swift
decisions:
  - "OCR fallback laissé en stub honnête (source=none) — pas de localisation fiable du rect overlay ghost ; AX-read-first est le vrai livrable"
  - "Usage --help imprimé AVANT ensureTrusted pour que le verify de build ne dépende d'aucune TCC interactive"
  - "Walking AX brut self-contained dans main.swift — AXClient inchangé (ne cible que l'app focalisée)"
metrics:
  duration: ~10min
  completed: 2026-06-08
---

# Quick 260608-sb3 : Probe SouffleuseCotypistObserve Summary

Nouvel exécutable dev `SouffleuseCotypistObserve` qui observe en boîte-noire (lecture AX externe seule) comment Cotypist rend son ghost-text, pendant qu'on pilote TextEdit avec des frappes synthétiques — base d'analyse comparative pour notre propre ghost.

## What Was Built

- **Package.swift** : product `.executable` + `.executableTarget SouffleuseCotypistObserve` (deps `SouffleuseAX` + `SouffleuseContext`), mirror exact du pattern `SouffleuseContextProbe`. Aucune autre modification.
- **main.swift (387 lignes)** — top-level code calqué sur `SouffleuseAXProbe` :
  - **Docstring éthique/légal** en tête : observation AX externe uniquement ; aucun debugger / patch / re-signature / contournement de Cotypist.
  - **Usage** (`--help` / `-h` / sans args) imprimé AVANT toute touche à l'AX → exit 0, pas de dépendance TCC.
  - **Helpers AX bruts** dans le probe : `cotypistPID()` (via NSWorkspace), `copyAttr`, `axString`, `axRect` (AXValueGetValue `.cgPoint`/`.cgSize`), `axChildren`, `walk(...)` récursif borné (maxDepth 12, garde-fou 5000 nœuds), `ghostCandidates(in:)`.
  - **Mode scan** : `AXUIElementCreateApplication(pid)` → dump role/subrole/value-preview/rect de l'app + chaque fenêtre (`kAXWindowsAttribute`).
  - **Mode observe** : active TextEdit (best-effort), pilote `testPhrase` char-par-char via `CGEvent.keyboardSetUnicodeString` (réplique inline, le probe poste ses propres touches), polling AX-read-first du ghost (20ms steps jusqu'au `--delay`), lecture préfixe via `client.snapshot()`, encode `Observation` Codable (`k/prefix/ghost/source/ts_ms/latency_ms`) en JSONL → fichier `--out` (défaut `/tmp/cotypist-observe.jsonl`) + stdout.
  - **Fallback OCR** : stub honnête marqué `// OCR fallback: best-effort` — `ScreenCapturer.hasPermission()` gate puis retourne nil (source="none") faute de localisation fiable du rect overlay.

## Build / Verify Result

- `swift build --target SouffleuseCotypistObserve` → **succès** (warning AppKit dans dépendance SouffleuseOverlay, hors de notre code).
- `swift run SouffleuseCotypistObserve --help` → usage scan/observe imprimé, **exit 0**, pas de crash, **pas de prompt TCC**.
- `grep SouffleuseCotypistObserve audit.sh` → **vide** (target hors SHIPPING_DIRS, print() autorisé).
- `bash audit.sh` → **6/6 verts, AUDIT PASSED**.
- `git diff --stat` → seuls `Package.swift` (+5) et le nouveau `main.swift` (+387). AXClient et code shipping intouchés.

## Deviations from Plan

None - plan exécuté tel qu'écrit. Le fallback OCR reste un stub best-effort conforme à l'intent explicite du plan (source="none" quand l'AX échoue ; AX-read-first est le chemin réel et complet).

## Notes / Out of Scope

- Le run réel `scan` / `observe` contre Cotypist live n'a PAS été exécuté (hors scope verify : nécessite Cotypist lancé + TextEdit focalisé + TCC Accessibility interactif).
- Câbler un capture+OCR ciblé sur le rect overlay (révélé par `scan`) est une amélioration future possible si l'AX-read-first ne suffit pas en pratique.

## Self-Check: PASSED
- FOUND: Souffleuse/Sources/SouffleuseCotypistObserve/main.swift
- FOUND: Package.swift contient SouffleuseCotypistObserve (product + target)
- FOUND commit fdb768a (Package.swift), d24152a (main.swift)
