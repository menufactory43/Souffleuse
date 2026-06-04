---
quick_id: 260604-k1v
phase: quick
plan: 260604-k1v
subsystem: update-mechanism
tags: [sparkle, spm, codesign, menu, info-plist]
dependency_graph:
  requires: []
  provides: [sparkle-update-channel]
  affects: [Souffleuse-executable, make-app.sh, Info.plist]
tech_stack:
  added: [Sparkle 2.9.2 (binary XCFramework, SPM)]
  patterns: [inside-out codesign, @MainActor wrapper, manual-only updater]
key_files:
  created:
    - Souffleuse/Sources/Souffleuse/UpdaterController.swift
    - .planning/quick/260604-k1v-int-grer-sparkle-2-maj-manuel-only-spm-n/SPARKLE-RELEASE.md
  modified:
    - Souffleuse/Package.swift
    - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
    - Souffleuse/Resources/Info.plist
    - Souffleuse/make-app.sh
decisions:
  - "Sparkle via SPM uniquement sur le target exécutable (jamais dans library/test targets)"
  - "automaticallyChecksForUpdates=false redondant avec Info.plist (défense en profondeur)"
  - "find build pour localiser Sparkle.framework — échec bruyant si introuvable (pas de chemin inventé)"
  - "Signature inside-out : XPC bundles signés avant framework outer (Downloader/Installer/Updater/Autoupdate)"
metrics:
  duration_minutes: 9
  tasks_completed: 5
  tasks_total: 5
  files_created: 2
  files_modified: 4
  completed_date: "2026-06-04"
---

# Quick Task 260604-k1v: Intégration Sparkle 2 (manuel-only, SPM) Summary

**One-liner:** Sparkle 2.9.2 intégré via SPM (exécutable uniquement) avec UpdaterController @MainActor, item menu manuel-only, Info.plist sans poll passif, et signature inside-out des XPC imbriqués dans make-app.sh.

---

## Tasks Completed

| Task | Name | Commit | Key files |
|------|------|--------|-----------|
| 1 | Dépendance SPM Sparkle (exécutable uniquement) | c13eaa8 | Package.swift |
| 2 | UpdaterController + item menu | 5322b1b | UpdaterController.swift, SouffleuseAppDelegate.swift |
| 3 | Clés Sparkle dans Info.plist | 1b26152 | Resources/Info.plist |
| 4 | Embed + signer Sparkle.framework (XPC inside-out) | f70ba84 | make-app.sh |
| 5 | Doc dev EdDSA / sign_update / appcast.xml | 11d77e8 | SPARKLE-RELEASE.md |

---

## Verifications Passed

- `swift package resolve` : Sparkle 2.9.2 téléchargé, Package.resolved muté
- `grep -c 'package: "Sparkle"' Package.swift` → 1 (uniquement dans le target Souffleuse)
- `swift build --target Souffleuse` : Build complete (118s), UpdaterController compilé
- `./audit.sh` → **AUDIT PASSED** (zéro print/NSLog/os_log dans UpdaterController.swift)
- Info.plist : SUFeedURL=`https://souffleuse.app/appcast.xml`, SUEnableAutomaticChecks=false, SUPublicEDKey=placeholder, SUScheduledCheckInterval **absent**
- `RELEASE=1 NOTARIZE=0 ./make-app.sh` : bundle produit, XPC signés inside-out, DMG signé Developer ID
- `otool -L` → `@rpath/Sparkle.framework/Versions/B/Sparkle` présent
- `codesign --verify --deep --strict` → **BUNDLE-SIGN-OK**

---

## Locked Decisions Respected

| Décision | Statut |
|---|---|
| Update mode = MANUAL ONLY (SUEnableAutomaticChecks=false, no SUScheduledCheckInterval) | Respecté |
| Vendoring = SPM (sparkle-project/Sparkle, from 2.6.0) | Respecté — 2.9.2 résolu |
| Distribution = signed Developer ID, NON notarisé (NOTARIZE=0) | Respecté |
| SUFeedURL = https://souffleuse.app/appcast.xml | Respecté |
| EdDSA : placeholder SUPublicEDKey + TODO dans Info.plist (aucun secret committé) | Respecté |

---

## Deviations from Plan

None — plan exécuté exactement tel qu'écrit. Sparkle.framework trouvé dans `build/Build/Products/Release/` (xcodebuild l'a embarqué via l'option Embed automatique du scheme SPM binary) ; la commande `find build -name 'Sparkle.framework'` l'a localisé sans ambiguïté.

---

## Known Stubs

- `SUPublicEDKey` = `PLACEHOLDER_REMPLACER_PAR_LA_CLE_PUBLIQUE_EDDSA` dans Info.plist : intentionnel. La clé publique réelle est générée manuellement par `generate_keys` (stocke la privée dans le trousseau macOS). SPARKLE-RELEASE.md §1 documente la procédure. Le placeholder doit être remplacé avant de déployer un appcast.

---

## Threat Flags

| Flag | File | Description |
|------|------|-------------|
| threat_flag: network-egress | UpdaterController.swift | Sparkle initie une requête HTTPS vers SUFeedURL sur action utilisateur explicite. Aucun poll passif (SUEnableAutomaticChecks=false). Conforme à la décision zero-leak de ARCHITECTURE.md:339. |

---

## Self-Check: PASSED

- UpdaterController.swift : FOUND
- SPARKLE-RELEASE.md : FOUND
- Commit c13eaa8 : FOUND
- Commit 5322b1b : FOUND
- Commit 1b26152 : FOUND
- Commit f70ba84 : FOUND
- Commit 11d77e8 : FOUND
