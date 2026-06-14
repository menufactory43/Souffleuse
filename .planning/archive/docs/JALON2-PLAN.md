# Jalon 2 — Injection système Accessibility

> Sortir Souffleuse de sa zone texte locale pour fonctionner **dans toutes les apps macOS** via Accessibility API. C'est ce qui fait la valeur réelle du produit vs un éditeur isolé.

## Pré-requis (état au démarrage)

Avant de coder, vérifier que :
- `git log` montre les 2 commits de Jalon 1 (Initial commit + gitignore update)
- `xcodebuild -scheme Souffleuse -derivedDataPath ./build build` réussit
- Lancement local fonctionne :
  ```bash
  BUILD_DIR=~/cocotypist/Souffleuse/build/Build/Products/Debug
  DYLD_FRAMEWORK_PATH="$BUILD_DIR" "$BUILD_DIR/Souffleuse"
  ```
  → fenêtre Souffleuse — Spike avec ghost text fonctionnel

Lire avant de commencer :
- `ARCHITECTURE.md` § 3.1 FocusObserver, § 3.4 GhostOverlay, § 5 Sécurité
- `BENCHMARKS.md` (rappel : Gemma 3 1B-pt, ~30 tok/s, TTFT ~90 ms)
- `JALON1.md` (où on en est techniquement)

## Définition of done

L'utilisateur lance Souffleuse depuis le menu bar. Il ouvre TextEdit, Notes, Mail compose, Safari champ texte. Il tape ≥3 caractères. Un texte gris apparaît après son caret. Tab insère. Esc rejette. Aucun ghost ne s'affiche dans un champ password ou dans une app blocklistée. ⌃⌥⌘S suspend l'app sans la quitter.

## Risques connus et contre-mesures

| # | Risque | Contre-mesure prévue |
|---|---|---|
| R1 | Apps Electron exposent un seul nœud AX opaque (Slack, VS Code, Discord) | Détecter via bundle ID + fallback exclusion en v1, allowlist progressive en v2 |
| R2 | Latence read AX sur gros documents (Notes, longs mails) | Tronquer le contexte aux 2048 derniers chars avant le caret |
| R3 | Conflit avec Tab natif (formulaires web, navigation entre champs) | Ne consommer Tab QUE si suggestion non vide, sinon laisser passer |
| R4 | Champ password lu accidentellement | Vérifier `kAXSubroleAttribute == "AXSecureTextField"` AVANT toute lecture |
| R5 | Race AX read vs frappe utilisateur | Snapshot du contexte au moment de la requête, abandon si focus change avant que le ghost arrive |
| R6 | Permission Accessibility manquante | Onboarding qui guide vers System Settings + bouton "Ouvrir Réglages" via URL scheme |
| R7 | `CGEventTap` peut nécessiter Input Monitoring séparément | Demander les 2 permissions à l'onboarding, vérifier les 2 statuts |
| R8 | macOS bloque les NSPanel level statusBar sans bonnes options | Tester `.floating` en fallback, `.canJoinAllSpaces` + `.stationary` indispensables |

## Découpage en 4 phases

Chaque phase a un livrable testable indépendamment. Séquentiel A → B → C → D.

---

### Phase 2.A — FocusObserver standalone (1-2 jours)

**But** : un module Swift qui, sans aucune UI, observe l'app frontale et expose une API claire pour :
- l'élément texte focalisé (nil si pas un text element)
- son texte courant (string)
- sa range de sélection / position de caret
- le rect écran du caret (CGRect)
- le bundle ID de l'app conteneur
- le subrole (pour exclure les password fields)

**Livrable**
- `Sources/Souffleuse/AX/AXClient.swift` (acteur isolé, code testable)
- `Sources/SouffleuseAXProbe/main.swift` — exécutable CLI qui print le contexte toutes les 500 ms : `[Mail] field=AXTextArea text="Bonjour Marie..." caret=42 rect=(120,300,12,16)`

**APIs Accessibility à utiliser**
```swift
AXIsProcessTrusted()                                    // statut permission
AXIsProcessTrustedWithOptions([                         // prompt si pas trusted
    kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
] as CFDictionary)

let systemWide = AXUIElementCreateSystemWide()
AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, ...)
AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, ...)
AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, ...)
AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, ...)
AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, ...)
AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ...)
// retourne AXValue de type CFRange via AXValueGetValue(_, .cfRange, &range)

AXUIElementCopyParameterizedAttributeValue(
    element,
    kAXBoundsForRangeParameterizedAttribute as CFString,
    AXValueCreate(.cfRange, &range)!,
    &result
)
// retourne AXValue type CGRect via AXValueGetValue(_, .cgRect, &rect)

AXObserverCreate(pid, callback, &observer)
AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString, refcon)
AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
```

**Edge cases à valider sur la démo CLI**
- TextEdit document ouvert, taper du texte
- Notes (Apple), taper dans une note
- Safari : champ adresse, champ recherche, champ form HTML
- Mail compose new message, taper dans le body
- 1Password recherche → DOIT retourner subrole secure → on doit l'ignorer
- Terminal.app → AXTextArea mais on ignore (blocklist)
- VS Code (Electron) → comportement à documenter (probablement nœud opaque)

**Pattern threading** : observer + lectures AX sur queue série `axQueue`. Surface API publique via actor pour Swift Concurrency safe.

**Test acceptance**
```bash
xcodebuild -scheme SouffleuseAXProbe build
./build/Build/Products/Debug/SouffleuseAXProbe
# → bouge le focus entre TextEdit, Notes, Safari, Mail
# → vérifier que chaque ligne imprimée contient bundle, role, texte, caret, rect
# → vérifier que les password fields n'apparaissent JAMAIS dans la sortie
```

---

### Phase 2.B — GhostOverlay détaché (1 jour)

**But** : une `NSPanel` qui peut afficher du texte gris à des coordonnées écran arbitraires, par-dessus n'importe quelle app, sans voler le focus.

**Livrable**
- `Sources/Souffleuse/Overlay/OverlayWindow.swift`
- Démo intégrée à `SouffleuseAXProbe` : affiche un overlay "GHOST" qui suit le caret de l'app frontale

**Spec NSPanel**
```swift
let panel = NSPanel(
    contentRect: .zero,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.level = .statusBar
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.ignoresMouseEvents = true
```

**Contenu**
- Un `NSTextField` non-éditable, font système 15pt, couleur `NSColor.tertiaryLabelColor`, fond clear
- Mise à jour de position via `panel.setFrame(rect, display: true)` à chaque event AX
- `panel.orderFront(nil)` quand on a une suggestion, `panel.orderOut(nil)` quand vide

**Conversions de coordonnées**
- AX retourne des rect en coords écran "Quartz" (origine top-left)
- AppKit utilise origine bottom-left avec `NSScreen.main`
- Conversion : `y_appkit = NSScreen.main.frame.height - y_quartz - height`

**Test acceptance**
- Bouger une fenêtre TextEdit → l'overlay ne suit PAS automatiquement (c'est attendu, on triggera sur AXValueChanged Phase 2.C)
- Cmd+Tab vers une autre app → l'overlay reste visible jusqu'à la prochaine update
- Passer en plein écran TextEdit → l'overlay reste visible
- 2 écrans → tester sur écran secondaire

---

### Phase 2.C — CGEventTap + injection AX (1 jour)

**But** : intercepter Tab/Esc au niveau session quand une suggestion est active, et injecter le texte accepté dans l'app cible.

**Livrable**
- `Sources/Souffleuse/Input/KeyInterceptor.swift` (CGEventTap + activation conditionnelle)
- `Sources/Souffleuse/AX/TextInjector.swift` (AX write + fallback)

**CGEventTap**
```swift
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: { proxy, type, event, refcon in
        // Si suggestion active et keyCode == 48 (Tab) ou 53 (Esc) :
        //   - dispatch sur main pour accept/reject
        //   - return nil pour consumer l'event
        // Sinon : return Unmanaged.passUnretained(event)
    },
    userInfo: nil
)
```

**Activation conditionnelle**
- Le tap n'est activé que quand `predictor.suggestion != ""`
- Sinon désactivé (`CGEvent.tapEnable(tap, enable: false)`) pour éviter de capter inutilement

**Injection texte**

Voie principale (propre, undoable dans l'app cible) :
```swift
let attr = kAXSelectedTextAttribute as CFString
AXUIElementSetAttributeValue(focusedElement, attr, suggestion as CFString)
```

Voie fallback (si l'app cible ne supporte pas l'écriture AX) :
```swift
let src = CGEventSource(stateID: .hidSystemState)
for char in suggestion {
    // CGEventCreateKeyboardEvent + setUnicodeString — voir GitHub gists
    // Mode "paste-like" : utiliser CGEvent + CGEventPost en posant directement
}
```

**Stratégie de choix** : essayer voie 1, si la valeur du champ n'a pas changé après 50 ms, fallback voie 2.

**Test acceptance**
- TextEdit : taper "bonjour ", attendre ghost, Tab → la suggestion s'insère, undo (Cmd+Z) la retire proprement
- Notes : idem
- Safari champ recherche : idem
- Mail compose body : idem
- Slack desktop : tester, documenter le résultat (probablement fallback nécessaire)

---

### Phase 2.D — Wire-up + onboarding (1-2 jours)

**But** : transformer le spike en app utilisable. Pas de fenêtre principale ; menu bar + onboarding + raccourci global.

**Livrable**
- Bundle `.app` propre avec Info.plist (CFBundleIdentifier, LSUIElement=true, NSAccessibilityUsageDescription, etc.)
- Refactor `SouffleuseApp.swift` : `setActivationPolicy(.accessory)` au lieu de `.regular`
- Onboarding (NSWindow simple) qui s'ouvre au premier lancement, guide vers Accessibility + Input Monitoring
- `NSStatusItem` avec menu : "Activée ✓ / Désactivée", "Préférences…", "Quitter"
- Raccourci global ⌃⌥⌘S via `NSEvent.addGlobalMonitorForEvents` pour toggle on/off
- Blocklist d'apps par défaut : `com.1password.*`, `com.apple.keychainaccess`, `com.apple.Terminal`, `org.alacritty`, banking apps

**Permissions**
```swift
// Au démarrage, vérifier sans prompter
if !AXIsProcessTrusted() {
    // Afficher l'écran d'onboarding qui ouvre System Settings
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}
```

**Bundle structure attendue**
```
Souffleuse.app/
  Contents/
    Info.plist             ← LSUIElement=true, NSAccessibilityUsageDescription
    MacOS/
      Souffleuse           ← binaire
    Resources/
      mlx-swift_Cmlx.bundle/ ← métallib MLX
      [icônes, traductions]
    Frameworks/            ← dylibs MLX
```

Note importante : `swift build` ne produit pas de bundle. Il faut soit :
- Utiliser `xcodebuild` + post-script qui crée le `.app`
- Migrer vers projet Xcode classique (recommandé à ce stade)
- Utiliser `swift-bundler` (3rd party)

**Test acceptance final du Jalon 2**
1. Lancer Souffleuse.app via Finder
2. Pas de fenêtre principale, juste l'icône menu bar
3. Si pas de permission AX : onboarding s'ouvre, instructions claires
4. Permission accordée : icône menu bar passe en état "active"
5. Ouvrir TextEdit, taper "Bonjour ", ghost gris apparaît
6. Tab insère, Esc rejette
7. Ouvrir 1Password recherche → AUCUN ghost
8. ⌃⌥⌘S → icône menu bar passe "inactive", plus de ghost dans TextEdit
9. Re-⌃⌥⌘S → réactivée

---

## Hors scope Jalon 2 (à reporter)

- **Architecture XPC 3-process** (UI / AXAgent / InferenceAgent) → **Jalon 2.5**. Faire d'abord marcher en monolithe, refactorer ensuite.
- Personnalisation utilisateur (snippets, profils par app) → Jalon 3
- Préférences UI complète → Jalon 3
- Notarization + distribution `.dmg` → Jalon 3
- Détection typos inline → Jalon 3
- Emoji `:smile:` → 😄 → Jalon 3
- Filtres qualité avancés (rejet répétitions, langue) → Jalon 3
- KV cache cross-frappe → Jalon 3+
- **Permission Screen Recording (fallback OCR pour Electron)** → Jalon 3, en **opt-in** (réglage caché par défaut). Cotypist le demande dès l'onboarding ; on s'en différencie en gardant l'angle "AX-only, je ne vois que le champ texte". Si R1 (Electron blocklisté) devient une plainte récurrente en feedback, on ajoute un toggle "Améliorer la couverture (Slack, VS Code, Discord)" qui active Screen Recording + pipeline Vision/OCR local pour extraire le contexte des nœuds AX opaques.

## Estimation totale

5-7 jours de dev solo. Phase la plus risquée : 2.A (premier contact avec AX). Phase la plus longue : 2.D (onboarding + bundle propre).

## Critères pour passer Jalon 2 → Jalon 3

Tous les tests d'acceptance Phase D passent **et** au moins une session de test réelle de 30 minutes d'usage quotidien (mails, notes, recherche Safari) sans crash et avec ressenti "ça aide" vs "ça gêne".

## Prochain commit attendu après ce plan

```
git checkout -b jalon-2
# coder Phase 2.A
git add Sources/Souffleuse/AX Sources/SouffleuseAXProbe Package.swift
git commit -m "Jalon 2.A: AXClient + AXProbe CLI"
```
