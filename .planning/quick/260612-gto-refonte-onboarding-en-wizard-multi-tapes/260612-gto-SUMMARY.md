---
phase: quick-260612-gto
plan: "01"
subsystem: onboarding
tags: [swift-ui, wizard, onboarding, permissions, accessibility]
dependency_graph:
  requires: []
  provides: [OnboardingWindow-wizard, onboarding-completion-fix, onboarding-resume]
  affects: [SouffleuseAppDelegate, OnboardingWindow]
tech_stack:
  added: [SwiftUI-NSHostingController, Observation-@Observable]
  patterns: [wizard-multi-step, pinned-footer, pull-1s-permissions]
key_files:
  created: []
  modified:
    - Souffleuse/Sources/Souffleuse/OnboardingWindow.swift
    - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
decisions:
  - "Wizard hébergé en NSHostingController-dans-NSWindow (pattern PreferencesWindow) — évite une réécriture AppKit, permet @Observable, SwiftUI animations"
  - "OnboardingModel @Observable @MainActor séparé de la vue racine — état polling permissions isolé, pas de copie dans les sous-vues"
  - "Timer 1s dans show() pour le refresh permissions (AXIsProcessTrusted / IOHIDCheckAccess / ScreenCapturer.hasPermission ne sont pas observables)"
  - "onChange(of: ghostReady()) retiré de VoiceStepView — la transition absent→installé est détectée par le Timer 1s de show(), évite un appel closure dans onChange"
  - "Complétion versionnée onboardingCompletedVersion écrite dans onFinished (jamais à l'ouverture) — corrige le bug historique"
metrics:
  duration: "~35 min"
  completed: "2026-06-12"
  tasks_completed: 3
  files_modified: 2
---

# Quick 260612-gto: Refonte onboarding en wizard multi-étapes — Summary

**One-liner:** Wizard SwiftUI multi-étapes (6 étapes, pied fixe, poll permissions 1s, complétion-à-la-fin, reprise macOS-relaunch) hébergé dans NSHostingController.

## Tasks Completed

| # | Task | Commit | Status |
|---|------|--------|--------|
| 1 | Réécrire OnboardingWindow en wizard SwiftUI multi-étapes | e0d628d | done |
| 2 | Câbler complétion-à-la-fin, reprise et override env dev dans l'AppDelegate | 83ba69e | done |
| 3 | Vérifier audit privacy et suite de tests | d465915 | done |

## What Was Built

### OnboardingWindow.swift (réécriture complète)

- `enum OnboardingStep: Int, CaseIterable` : welcome/permissions/language/voice/howItWorks/done avec `preferredSize: CGSize`, `intermediateIndex: Int?`, `intermediateCount = 4`.
- `OnboardingModel @Observable @MainActor` : `currentStep`, `axGranted/imGranted/screenGranted`, `selectedLanguage`, `refreshPermissions()`.
- `OnboardingRootView` : dispatch terminal (welcome/done sans pips) vs scrollLayout (en-tête pips + ScrollView + pied FIXE hors-scroll).
- `OnboardingProgressHeader` : « Étape X sur 4 » + capsules sang-de-bœuf animées.
- `OnboardingFooter` : Retour (secondaire) / Continuer (sang-de-bœuf, gaté par étape).
- `PermissionCard` : badge SF Symbol, état live (✓ accordée / à accorder / optionnel), boutons Autoriser (prompt direct) + Ouvrir Réglages, `DisclosureGroup` encart d'aide.
- `ModelCard` : status live depuis `manager.status(for:)` + `isReadyExternally()`, progress bar, bouton Télécharger/Réessayer.
- Étapes language (Picker PrimaryLanguage → onLanguageChange), howItWorks (visuel ghost simulé + 3 puces), done (✓ sang-de-bœuf, rappel, gate AX+IM).
- Resize animé : `window.setFrame` clampé au `screen.visibleFrame` à chaque tick du Timer.
- `Color.sangDeBoeuf` local (copie exacte du pattern PreferencesWindow.swift, clair/dark).

### SouffleuseAppDelegate.swift (diffs ciblés)

- `onboardingVersion = 1` (constante statique privée).
- `shouldShowOnboarding()` : override `SOUFFLEUSE_ONBOARDING` (fresh/1) en tête ; accepte `onboardingDone` OU `onboardingCompletedVersion >= 1`.
- `makeOnboardingWindow()` : passe `onFinished` (écrit `onboardingCompletedVersion`), `initialStep` (reprise depuis `onboardingProgressStep`), `onProgress` (persist à chaque avancée).
- `showOnboarding()` : suppression de `UserDefaults.standard.set(true, "onboardingDone")` — complétion déplacée dans `onFinished`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Retiré onChange(of: ghostReady()) de VoiceStepView**
- **Found during:** Task 3 review
- **Issue:** `ghostReady()` est une closure, pas une propriété `@Observable` — `onChange` ne la suivrait pas correctement entre les ticks.
- **Fix:** Suppression de `@State wasGhostReady` et du `onChange`. La transition est détectée par le Timer 1s de `show()` qui appelle déjà `onGhostInstalled`.
- **Files modified:** `OnboardingWindow.swift`
- **Commit:** d465915

## Verification Results

| Check | Result |
|-------|--------|
| `swift build` | Build complete (4s) |
| `audit.sh` | 6/6 OK — aucun print/NSLog/os_log, invariants privacy intacts |
| `swift test` | 890 tests en 78 suites — verts, aucune régression |

## Known Stubs

Aucun — tous les chemins de données sont câblés sur des sources live (`ModelDownloadManager`, `AXClient.isTrusted`, `IOHIDCheckAccess`, `ScreenCapturer.hasPermission()`).

## Threat Flags

Aucune nouvelle surface réseau ou chemin d'accès user-data introduite. Toutes les sources de contexte restent in-process.

## Self-Check: PASSED

- `OnboardingWindow.swift` modifié ✓
- `SouffleuseAppDelegate.swift` modifié ✓
- Commits e0d628d, 83ba69e, d465915 présents ✓
- `audit.sh` : PASSED ✓
- `swift test` : 890 tests verts ✓
