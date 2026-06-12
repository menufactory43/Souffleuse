---
phase: quick-260612-ij2
plan: 01
subsystem: onboarding
tags: [onboarding, permissions, input-monitoring, launch-at-login, ghost-try, SMAppService]
dependency_graph:
  requires: [260612-gto]
  provides: [onboarding-permission-reminder, ghost-try-field, launch-at-login-toggle]
  affects: [SouffleuseAppDelegate, OnboardingWindow]
tech_stack:
  added: [ServiceManagement, NSViewRepresentable/NSTextField (GhostTryField)]
  patterns: [IOHIDCheckAccess permission gate, SMAppService toggle pattern (mirrors PreferencesWindow)]
key_files:
  modified:
    - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
    - Souffleuse/Sources/Souffleuse/OnboardingWindow.swift
decisions:
  - "canTryGhost ferme sur predictor.isModelReady plutot que ghostReady (GGUF present) : isModelReady signifie que le moteur est charge et peut generer, pas seulement que le fichier GGUF existe"
  - "GhostTryField via NSViewRepresentable/NSTextField plutot que TextField SwiftUI : AX expose caret+bounds de facon fiable sur NSTextField"
  - "Reprise a l'etape permissions (rawValue 1) pour utilisateur deja onboarde a qui manque une permission : evite de lui refaire l'intro entiere"
metrics:
  duration: "~10 minutes"
  completed: "2026-06-12"
  tasks_completed: 3
  files_modified: 2
---

# Quick 260612-ij2: Completer l'onboarding — rappel permission, essai reel, login item

**One-liner:** Cinq ajouts cibles a l'onboarding wizard (260612-gto) : gate Input Monitoring dans shouldShowOnboarding, reprise a l'etape permissions pour utilisateur deja onboarde, logo app sur l'ecran Bienvenue, ligne de reassurance mots de passe, toggle SMAppService Lancer au demarrage, et essai reel du souffle via NSTextField AppKit avec repli statique.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | shouldShowOnboarding — check Input Monitoring + reprise etape permissions | 296343f | SouffleuseAppDelegate.swift |
| 2 | Logo Bienvenue, reassurance mots de passe, toggle Lancer au demarrage | 80c5f81 | OnboardingWindow.swift |
| 3 | Essai reel du souffle dans « Comment ca marche » (GhostTryField + repli) | 6e44d7b | OnboardingWindow.swift, SouffleuseAppDelegate.swift |

## Changes Summary

### Task 1 — SouffleuseAppDelegate.swift

- `import IOKit.hid` ajoute (apres `import Foundation`)
- Propriete calculee `inputMonitoringGranted: Bool` (miroir exact de `OnboardingModel.refreshPermissions`) ajoutee juste au-dessus de `shouldShowOnboarding()`
- `shouldShowOnboarding()` : le gate inclut desormais `&& inputMonitoringGranted` — le wizard se rouvre quand Tab/Esc est inerte (symptome « ghost visible, Tab ne fait rien »)
- `makeOnboardingWindow()` : `resumeStep` calcule avec logique permission-aware — si l'utilisateur est deja onboarde ET qu'AX ou Input Monitoring manque, on ouvre directement a `OnboardingStep.permissions.rawValue` (= 1)

### Task 2 — OnboardingWindow.swift

- `import ServiceManagement` ajoute
- `WelcomeStepView` : logo 72x72 `NSApp.applicationIconImage` avec `RoundedRectangle(cornerRadius: 16)`, au-dessus du titre dans un `VStack(spacing: 18)`
- `PermissionsStepView` : ligne `HStack` avec `lock.fill` + « Les champs de mot de passe ne sont jamais lus, ni les apps bancaires. » inseree entre la carte Enregistrement de l'ecran et le DisclosureGroup d'aide
- `DoneStepView` : `@State private var launchAtLogin` initialise sur `SMAppService.mainApp.status == .enabled`; `Toggle("Lancer Souffleuse a l'ouverture du Mac")` avec `.toggleStyle(.checkbox)`, `.onChange` cable sur `try SMAppService.mainApp.register()/unregister()`, fallback silencieux sur erreur

### Task 3 — OnboardingWindow.swift + SouffleuseAppDelegate.swift

- `GhostTryField: NSViewRepresentable` ajoute (struct `private`) : `NSTextField` avec `roundedBezel`, auto-focus + caret en fin de seed via `DispatchQueue.main.async`
- `HowItWorksStepView` recoit `canTryGhost: () -> Bool` ; quand vrai → `GhostTryField(placeholderSeed: "Bonjour, je voulais vous dire que ")` dans un `VStack` avec instruction; sinon → maquette statique existante
- `OnboardingRootView` : propriete `canTryGhost: () -> Bool` ajoutee ; `stepContent` case `.howItWorks` passe `canTryGhost: canTryGhost`
- `OnboardingWindow.init` : parametre `canTryGhost: @escaping () -> Bool` ajoute apres `ghostReady`; passe a `OnboardingRootView`
- `makeOnboardingWindow()` : passe `canTryGhost: { [predictor] in predictor.isModelReady }`
- Le bouton Continuer sur l'etape howItWorks reste `canContinue: true` — non modifie

## Verification

- `swift build` : Build complete (tous les targets, pas d'erreur ni de warning)
- `swift test` : **890 tests passed** (0 failed, 0 skipped) — aucune regression
- `./audit.sh` : **AUDIT PASSED** — 6/6 checks verts (pas de `print`/`NSLog` ajoutes, pas de champ user logge, `GhostTryField` n'introduit pas de log)

## Deviations from Plan

None — plan execute exactement tel qu'ecrit. Les trois taches correspondent exactement aux cinq points du brief (3+4+5 en Task 2, 2 en Task 3, 1 en Task 1).

## Diagnostic pour l'orchestrateur (Task 3 — essai reel)

Lors du test live de l'etape « Comment ca marche » :

**Si le ghost n'apparait pas dans le champ d'essai :**

1. Lancer l'app avec `SOUFFLEUSE_PREDICT_LOG=/tmp souffleuse` et inspecter `/tmp/souffleuse-tick.log`
2. Chercher un `tick_gate_fail` avec l'une des raisons :
   - `no_caret` — le caret AX du NSTextField n'est pas visible (fenetre pas au premier plan ?)
   - `not_text_element` — l'AX du champ n'est pas reconnu comme `isTextElement` (peu probable sur NSTextField standard)
   - `secure_field` — ne devrait pas s'appliquer (le champ n'est pas `isSecureField`)
   - `bundle_blocked` — `app.cocotypist.Souffleuse` ne devrait pas etre dans la blocklist
3. Verifier que l'overlay `OverlayWindow` (NSPanel non-activant) s'affiche **au-dessus** de la fenetre d'onboarding

**Si `canTryGhost()` retourne false et la maquette statique s'affiche :**
`predictor.isModelReady` = `runtime.canGenerate` = `llamaReady`. Verifier que le modele GGUF est telecharge et charge (etape Voice du wizard avant howItWorks).

## Known Stubs

None.

## Self-Check: PASSED

- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` — modifie, build OK
- `Souffleuse/Sources/Souffleuse/OnboardingWindow.swift` — modifie, build OK
- Commits 296343f, 80c5f81, 6e44d7b — tous presents dans `git log`
- 890 tests verts, audit.sh vert
