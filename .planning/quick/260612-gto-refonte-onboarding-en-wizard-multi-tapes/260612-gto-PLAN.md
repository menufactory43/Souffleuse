---
phase: quick-260612-gto
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Souffleuse/Sources/Souffleuse/OnboardingWindow.swift
  - Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift
autonomous: true
requirements: [ONBOARD-WIZARD]
must_haves:
  truths:
    - "Au premier lancement, l'utilisateur voit un wizard multi-étapes (pas une page unique)"
    - "Chaque étape intermédiaire montre une jauge de progression « Étape X sur Y » et un pied de page fixe (Retour/Continuer) qui ne défile jamais"
    - "Le bouton Continuer des permissions est désactivé tant que les 2 permissions requises ne sont pas accordées"
    - "Un encart d'aide couvre les pépins de permission courants en français simple"
    - "La complétion (« onboardingCompletedVersion ») n'est écrite QUE quand l'utilisateur termine le wizard, pas à l'ouverture"
    - "Si macOS force un relancement pendant les permissions, le wizard reprend à l'étape atteinte (« onboardingProgressStep »)"
    - "Un ancien utilisateur (onboardingDone=true + AX accordée + ghost prêt) ne revoit PAS l'onboarding"
    - "SOUFFLEUSE_ONBOARDING=1 force l'affichage ; =fresh simule un premier lancement à l'étape 1"
  artifacts:
    - path: "Souffleuse/Sources/Souffleuse/OnboardingWindow.swift"
      provides: "Wizard SwiftUI multi-étapes hébergé dans NSWindow, même signature init + onFinished/onProgress"
      contains: "enum OnboardingStep"
    - path: "Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift"
      provides: "Câblage complétion-à-la-fin + reprise + override env dev"
      contains: "onboardingCompletedVersion"
  key_links:
    - from: "OnboardingWindow (SwiftUI)"
      to: "AXClient.ensureTrusted / IOHIDRequestAccess / ScreenCapturer.forcePermissionPrompt"
      via: "boutons Autoriser des cartes de permission"
      pattern: "forcePermissionPrompt|IOHIDRequestAccess|ensureTrusted"
    - from: "SouffleuseAppDelegate.showOnboarding"
      to: "UserDefaults onboardingCompletedVersion"
      via: "callback onFinished (PAS à l'ouverture)"
      pattern: "onboardingCompletedVersion"
---

<objective>
Remplacer l'onboarding mono-page actuel (`OnboardingWindow`, AppKit, scroll unique) par un **wizard multi-étapes** SwiftUI hébergé dans `NSWindow`, inspiré de Cotabby (`/tmp/cotabby-ref`), DA Souffleuse conservée (sang-de-bœuf #8c2b21, titres serif, didascalies serif italique, jamais de ✗ rouge), copy française non-technique.

Purpose : l'onboarding actuel empile tout sur une page et écrit la complétion À L'OUVERTURE (bug). Le wizard guide étape par étape, couvre robustement les pépins de permission, et ne marque « fait » qu'à la fin — avec reprise si macOS force un relancement pendant l'octroi des permissions.

Output : `OnboardingWindow.swift` réécrit en wizard SwiftUI + diffs ciblés dans `SouffleuseAppDelegate.swift` (complétion-à-la-fin, reprise, override env dev). Aucune autre surface touchée.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@./CLAUDE.md

<critical_constraints>
- Swift 6 strict concurrency : tout AppKit/SwiftUI est `@MainActor` ; types-frontière `Sendable` ; closures cross-isolation `@Sendable`/`@MainActor`.
- `audit.sh` doit passer : AUCUN `print`/`NSLog`/`os_log` ; logs uniquement via `Log.info/warn/error(.module, "event_litéral")` avec event `StaticString`. (Cette surface ne logue quasiment rien — préférer ZÉRO log nouveau.)
- La suite (~640 `@Test`) reste verte. Ne pas casser de symbole public consommé ailleurs.
- `ModelDownloadManager` est `@Observable` → une vue SwiftUI peut l'observer directement (pas de Timer pour le download). Le polling 1 s reste nécessaire pour l'ÉTAT DES PERMISSIONS (AX/Input/Screen ne sont pas observables).
- DA : sang-de-bœuf réservé à l'action primaire + cue « à accorder » ; titres serif (`.fontDesign(.serif)`) ; didascalies serif italique ; reste = SwiftUI natif, couleurs sémantiques système. Jamais de ✗ rouge.
- Copy français NON technique. Interdits : « TCC », « API », « accessibilité API », « GGUF », « LLM ». « modèle » toléré mais préférer « la voix » / « le moteur local ». Titres de permission = libellés EXACTS des volets Réglages FR.
</critical_constraints>

<reference_implementation>
Cotabby cloné en lecture seule. À CONSULTER pour la structure (ne pas copier le contenu, c'est une autre app) :
- `/tmp/cotabby-ref/Cotabby/UI/WelcomeView.swift` — structure wizard, enum d'étapes, pied fixe, pips de progression, tailles de fenêtre par étape.
- `/tmp/cotabby-ref/Cotabby/UI/WelcomePermissionStepView.swift` — cartes de permission à état live.
- `/tmp/cotabby-ref/Cotabby/App/Coordinators/WelcomeCoordinator.swift` — complétion versionnée, reprise d'étape, clamp de redimensionnement fenêtre.
Note : Cotabby a des étapes template/keybind qu'on REMPLACE par les étapes Souffleuse ci-dessous.
</reference_implementation>

<existing_signatures>
Réutiliser tel quel (ne PAS réécrire ces helpers) :

`OnboardingWindow.init` (signature À PRÉSERVER, + 2 nouveaux paramètres) :
```swift
init(
    modelDownloads: ModelDownloadManager,
    ghostProvider: @escaping () -> DownloadableModel?,
    ghostReady: @escaping () -> Bool,
    translation: DownloadableModel?,
    initialLanguage: PrimaryLanguage,
    onLanguageChange: @escaping @MainActor (PrimaryLanguage) -> Void,
    onGhostInstalled: (@MainActor () -> Void)? = nil,
    // NOUVEAU :
    onFinished: @escaping @MainActor () -> Void,      // appelé quand l'utilisateur TERMINE le wizard
    initialStep: Int = 0,                             // reprise (index d'étape atteint)
    onProgress: @escaping @MainActor (Int) -> Void    // appelé à chaque avancée d'étape (persistance reprise)
)
public func show()
public func close()
```

Helpers permission (DÉJÀ présents, réutiliser) :
- `AXClient.isTrusted` (Bool, @MainActor) — état AX.
- `AXClient.ensureTrusted(prompt: true)` — déclenche le prompt système AX. (Si la signature exacte diffère, grep `ensureTrusted`/`isTrusted` dans `Sources/SouffleuseAX/AXClient.swift` ; à défaut le lien Réglages reste le fallback.)
- `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted` — état Surveillance des entrées. `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` — prompt (import `IOKit.hid`).
- `ScreenCapturer.hasPermission()` — état écran. `await ScreenCapturer.forcePermissionPrompt()` — prompt écran (enregistre le bundle dans TCC).

Deep links Réglages (fallback « Ouvrir Réglages ») :
- Accessibilité : `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- Surveillance des entrées : `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`
- Enregistrement de l'écran : `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`

Modèles : `model.approxSizeMB` (Int, Mo), `manager.status(for: model)` → `.ready/.downloading(p)/.absent/.failed`, `manager.download(model)`, `manager.isReady(model)`. `PrimaryLanguage` (`GGUFModelOption.swift`) : `.french` / `.multilingual`, `.allCases`, `.label`.

Marque (réutiliser l'équivalent SwiftUI de `Brand` / `Color.sangDeBoeuf` de PreferencesWindow.swift) :
- Sang-de-bœuf dynamique : #8c2b21 clair → #d06a5d dark. Définir un `Color.sangDeBoeuf` local (copier le pattern `NSColor(name: nil) { appearance in … }` de `PreferencesWindow.swift`).
- Titre serif : `.font(.system(size: 22, weight: .semibold, design: .serif))`.
- Didascalie : `.font(.system(size: 13, design: .serif)).italic().foregroundStyle(.secondary)`.
</existing_signatures>

<step_spec>
Enum d'étapes (terminales = welcome/done sans pips ; intermédiaires = pips + pied fixe) :
```swift
enum OnboardingStep: Int, CaseIterable {
    case welcome      // terminale
    case permissions
    case language
    case voice        // téléchargement modèle
    case howItWorks
    case done         // terminale
}
```
`Étape X sur Y` : X/Y comptent SEULEMENT les étapes intermédiaires (permissions=1, language=2, voice=3, howItWorks=4 → Y=4).

Copy EXACTE par étape (réutiliser les descriptions de permission/modèle déjà écrites dans l'ancien fichier) :

ÉTAPE welcome (terminale, centrée, pas de pips) :
- Titre serif : « Bienvenue dans Souffleuse »
- Didascalie serif italique : « Souffleuse vit dans votre barre de menus et souffle le mot juste là où vous écrivez. Quelques réglages, puis elle s'efface. »
- Bouton primaire (sang-de-bœuf) : « Commencer »

ÉTAPE permissions (pips, pied fixe ; Continuer gaté sur AX + Surveillance accordées) :
- Titre serif : « Ce qu'il faut autoriser »
- Carte « Accessibilité » (requise) — sous-titre : « Lit le champ de saisie où vous êtes, et y écrit la suggestion que vous acceptez. » — bouton « Autoriser » → `AXClient.ensureTrusted(prompt: true)` ; fallback « Ouvrir Réglages ».
- Carte « Surveillance des entrées » (requise) — sous-titre : « Capte Tab et Esc, et seulement eux, quand une suggestion est à l'écran. » — bouton « Autoriser » → `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` ; fallback « Ouvrir Réglages ».
- Carte « Enregistrement de l'écran » (optionnelle, capsule « Optionnel », ne bloque jamais Continuer) — sous-titre : « Laissez Souffleuse lire ce qui est à l'écran pour des suggestions plus justes. Reste éteint tant que vous ne l'accordez pas. » — bouton « Autoriser » → `await ScreenCapturer.forcePermissionPrompt()`.
- Encart d'aide (DisclosureGroup repliable, fermé par défaut), titre « Un souci pour autoriser ? », contenu (puces, français simple) :
  - « Souffleuse n'apparaît pas dans la liste ? Cliquez « Autoriser » ci-dessus : elle s'ajoutera toute seule, puis activez l'interrupteur en face de son nom dans Réglages. »
  - « macOS vous demande de relancer Souffleuse ? C'est normal après avoir autorisé. Relancez : vous reprendrez ici même, vos réglages sont gardés. »
  - « Le bouton reste «  à accorder » ? Vérifiez que l'interrupteur est bien ALLUMÉ (bleu) dans Réglages, pas juste coché. »
- État des cartes (live, polling 1 s) : accordée → « ✓ accordée » (secondaire) ; requise non accordée → « à accorder » (sang-de-bœuf cue) ; optionnelle non accordée → « optionnel » (tertiaire). JAMAIS de ✗ rouge.

ÉTAPE language (pips, pied fixe) :
- Titre serif : « Votre langue »
- Didascalie : « Sert à vous conseiller la bonne voix : en français, une petite voix rapide suffit ; pour plusieurs langues, une voix multilingue. Modifiable à tout moment. »
- `Picker`/segmented `PrimaryLanguage.allCases` (labels), sélection initiale = `initialLanguage` ; sur changement → `onLanguageChange(lang)` (l'AppDelegate réaligne la voix conseillée — voir `makeOnboardingWindow`).

ÉTAPE voice (pips, pied fixe ; Continuer autorisé si téléchargement EN COURS ou déjà installé) :
- Titre serif : « La voix »
- Carte « Modèle du souffle » (requise) — sous-titre : « Le moteur local qui souffle vos suggestions. Une minute environ, 100 % sur votre Mac, rien ne sort. » — bouton « Télécharger (X Mo) » (`model.approxSizeMB`) ; progress live via `manager.status(for:)` (observé) ; « ✓ installé » si `ghostReady()` ou `.ready`.
- Carte « Modèle de traduction » (optionnelle, capsule « Optionnel ») — sous-titre : « Pour la traduction et la relecture par ton. Téléchargé tout seul au premier usage si vous passez. »
- Gate Continuer : ghost `.ready`/`ghostReady()` OU `.downloading` (il finit en arrière-plan, rappelé à l'étape done).

ÉTAPE howItWorks (pips, pied fixe) :
- Titre serif : « Comment ça marche »
- Visuel simulé : une ligne de texte « Bonjour, je vous » + ghost gris « écris ce mot » (Text concaténé, ghost en `.foregroundStyle(.tertiary)`).
- Puces : « Le mot juste apparaît en gris : appuyez sur **Tab** pour l'accepter. » / « Il ne vous va pas ? **Esc**, ou continuez d'écrire : il s'efface. » / « Souffleuse reste dans la barre de menus, en haut à droite. »

ÉTAPE done (terminale, centrée) :
- Grand « ✓ » (sang-de-bœuf).
- Titre serif : « C'est prêt »
- Rappel : « Tab pour accepter, Esc pour ignorer. »
- Si téléchargement encore en cours : ligne « La voix finit de se télécharger en arrière-plan — vous pourrez écrire dès qu'elle est prête. »
- Bouton primaire (sang-de-bœuf) « Commencer à écrire » — DÉSACTIVÉ tant que les permissions REQUISES (AX + Surveillance) ne sont pas accordées ; au clic → `onFinished()` puis `close()`.

Pied de page fixe (étapes intermédiaires, HORS du ScrollView) :
- Gauche : « Retour » (secondaire) — revient d'une étape.
- Droite : « Continuer » (sang-de-bœuf, désactivé selon le gate de l'étape).
- En-tête pips : « Étape X sur 4 » + 4 capsules (remplie = sang-de-bœuf pour l'étape courante/passées, creuse sinon).
</step_spec>

<window_sizing>
Tailles préférées par étape (le owner AppKit anime le resize, recentre, clampe au visibleFrame de l'écran ; le contenu défile pour absorber le débordement) :
- welcome : 480×360 · permissions : 560×640 · language : 480×420 · voice : 520×480 · howItWorks : 500×460 · done : 480×400.
Implémentation : exposer `var preferredSize: CGSize` sur `OnboardingStep` ; à chaque changement d'étape, `window.setFrame(_, display:, animate: true)` recentré et clampé à `screen.visibleFrame`. Le `NSHostingController` suit (`host.view.frame`).
</window_sizing>
</context>

<tasks>

<task type="auto">
  <name>Task 1 : Réécrire OnboardingWindow en wizard SwiftUI multi-étapes</name>
  <files>Souffleuse/Sources/Souffleuse/OnboardingWindow.swift</files>
  <action>
Remplacer entièrement le contenu de `OnboardingWindow.swift` (la version AppKit mono-page) par un wizard SwiftUI hébergé en `NSHostingController`-dans-`NSWindow` (pattern de `PreferencesWindow.swift`).

Structure :
1. `enum OnboardingStep: Int, CaseIterable` (welcome, permissions, language, voice, howItWorks, done) + `var preferredSize: CGSize` + helper `intermediateIndex`/`intermediateCount` pour « Étape X sur 4 » (terminales exclues).
2. `Color.sangDeBoeuf` local (copier le pattern dynamique clair/dark de PreferencesWindow.swift). Helpers de fonte serif via `.font(.system(size:weight:design:.serif))` et `.italic()`.
3. `@MainActor @Observable final class OnboardingModel` (ou `@State` dans la vue racine) portant : `currentStep`, état permissions (3 Bool rafraîchis par poll 1 s : AX via `AXClient.isTrusted`, Surveillance via `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted`, Écran via `ScreenCapturer.hasPermission()`), `selectedLanguage`. Le download est lu directement depuis `modelDownloads` (`@Observable`) — pas de copie d'état.
4. Vue racine SwiftUI `OnboardingRootView` : `switch currentStep` → sous-vue par étape. Étapes intermédiaires enveloppées dans un layout commun { en-tête pips (« Étape X sur 4 » + 4 capsules), `ScrollView` du contenu, pied FIXE hors-scroll (Retour / Continuer) }. Terminales (welcome/done) = layout centré sans pips ni pied.
5. Cartes de permission (sous-vue réutilisable `PermissionCard`) : badge SF Symbol dans rectangle arrondi teinté + titre (libellé EXACT FR) + sous-titre 1 ligne + bouton « Autoriser » (action prompt direct) + bouton « Ouvrir Réglages » (deep link) + état live (✓ accordée / à accorder / optionnel ; capsule « Optionnel » si optionnelle). Prompts directs : Accessibilité → `AXClient.ensureTrusted(prompt: true)` (si signature absente, garder seulement « Ouvrir Réglages ») ; Surveillance → `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` ; Écran → `Task { await ScreenCapturer.forcePermissionPrompt() }`. Encart d'aide = `DisclosureGroup` fermé par défaut avec les 3 puces du step_spec.
6. Carte modèle (`ModelCard`) : titre + sous-titre + bouton « Télécharger (X Mo) » / progress / « ✓ installé », lue depuis `manager.status(for:)` et `ghostReady()`/`isReady`.
7. Étapes language (Picker `PrimaryLanguage` → `onLanguageChange`), howItWorks (visuel ghost simulé + 3 puces), welcome/done terminales.
8. Gates Continuer : permissions → `axGranted && imGranted` ; voice → ghost prêt OU en téléchargement ; autres → toujours ouvert. Bouton « Commencer à écrire » de `done` désactivé tant que `axGranted && imGranted` faux ; au clic → `onFinished(); close()`.
9. `init` : MÊME signature qu'avant + `onFinished`, `initialStep`, `onProgress` (voir <existing_signatures>). `currentStep = OnboardingStep(rawValue: initialStep) ?? .welcome`. À chaque avancée d'étape, appeler `onProgress(currentStep.rawValue)`.
10. `show()`/`close()` : `show()` ordonne la fenêtre + démarre le `Timer` 1 s (`MainActor.assumeIsolated { refresh permissions }`) ; `close()` invalide le timer et `orderOut`. `isReleasedWhenClosed = false`.
11. Redimensionnement par étape : à chaque changement de `currentStep`, animer `window.setFrame` vers `step.preferredSize`, recentré, clampé à `screen.visibleFrame`.

Conserver `window.title` (ex. « Bienvenue dans Souffleuse »). Concurrency : tout `@MainActor` ; aucun `print`/`NSLog` ; pas de nouveau log (ou seulement `Log.*` event `StaticString` si strictement nécessaire). Ne PAS exposer de nouveau symbole `public` consommé hors module au-delà de l'init.
  </action>
  <verify>
    <automated>cd Souffleuse && swift build 2>&1 | tail -20</automated>
  </verify>
  <done>`swift build` compile sans erreur. `OnboardingWindow` expose un init avec `onFinished`/`initialStep`/`onProgress` + `show()`/`close()`. Le fichier contient `enum OnboardingStep` et un pied de page fixe hors ScrollView pour les étapes intermédiaires. Aucun `print`/`NSLog`.</done>
</task>

<task type="auto">
  <name>Task 2 : Câbler complétion-à-la-fin, reprise et override env dev dans l'AppDelegate</name>
  <files>Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift</files>
  <action>
Modifications ciblées (NE PAS toucher au reste de l'AppDelegate) :

1. `shouldShowOnboarding()` (~ligne 578) — ajouter en TÊTE l'override env dev, AVANT toute autre logique :
```swift
if let env = ProcessInfo.processInfo.environment["SOUFFLEUSE_ONBOARDING"] {
    if env == "fresh" {
        // Simule un premier lancement : ignore les clés et repart de l'étape 1.
        UserDefaults.standard.removeObject(forKey: "onboardingProgressStep")
        return true
    }
    if env == "1" { return true }
}
```
Garder ENSUITE la rétrocompat existante : un ancien utilisateur (`onboardingDone == true`) AVEC `AXClient.isTrusted` ET `ghostReady` ne revoit pas l'onboarding. Étendre la condition pour reconnaître AUSSI la nouvelle clé versionnée :
```swift
let onboarded = UserDefaults.standard.bool(forKey: "onboardingDone")
    || UserDefaults.standard.integer(forKey: "onboardingCompletedVersion") >= Self.onboardingVersion
let ghostReady = GGUFModelOption.option(forID: store.ggufModelID).isResolvable
if onboarded && AXClient.isTrusted && ghostReady { return false }
return true
```
Ajouter `private static let onboardingVersion = 1` sur la classe.

2. `makeOnboardingWindow()` (~ligne 592) — passer les 3 nouveaux arguments à l'init :
   - `onFinished: { UserDefaults.standard.set(Self.onboardingVersion, forKey: "onboardingCompletedVersion") }` (la complétion s'écrit ICI, à la fin).
   - `initialStep:` — si `SOUFFLEUSE_ONBOARDING == "fresh"`, forcer `0` ; sinon `UserDefaults.standard.integer(forKey: "onboardingProgressStep")` (0 par défaut).
   - `onProgress: { step in UserDefaults.standard.set(step, forKey: "onboardingProgressStep") }` (persiste l'étape atteinte pour la reprise après relancement forcé par macOS).
   Conserver les arguments existants inchangés (`modelDownloads`, `ghostProvider`, `ghostReady`, `translation`, `initialLanguage`, `onLanguageChange`, `onGhostInstalled`).

3. `showOnboarding()` (~ligne 623) — SUPPRIMER la ligne `UserDefaults.standard.set(true, forKey: "onboardingDone")` (c'était le bug : complétion à l'ouverture). La complétion passe désormais par `onFinished`. Garder `win.show()`.

Laisser intacts : le menu « Permissions… » (~ligne 906) et `openOnboarding()` (~ligne 1092) — ils réutilisent `makeOnboardingWindow()`, donc héritent du nouveau câblage sans changement. (Ré-ouvrir via le menu reprend à `onboardingProgressStep` — comportement acceptable.)

Concurrency : tout reste `@MainActor` (méthodes existantes). Aucun `print`/`NSLog`.
  </action>
  <verify>
    <automated>cd Souffleuse && swift build 2>&1 | tail -20</automated>
  </verify>
  <done>`swift build` compile. `shouldShowOnboarding` lit `SOUFFLEUSE_ONBOARDING` (1/fresh) et la clé `onboardingCompletedVersion`. `showOnboarding` n'écrit PLUS `onboardingDone` à l'ouverture. `makeOnboardingWindow` passe `onFinished`/`initialStep`/`onProgress`. Aucun `print`/`NSLog`.</done>
</task>

<task type="auto">
  <name>Task 3 : Vérifier audit privacy et suite de tests</name>
  <files>Souffleuse/Sources/Souffleuse/OnboardingWindow.swift, Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift</files>
  <action>
Garde-fous finaux (pas de nouveau code de feature) :
1. Lancer `Souffleuse/audit.sh` — doit passer. Si échec pour `print`/`NSLog`/`os_log` introduits dans les 2 fichiers modifiés, les retirer (cette surface ne doit quasiment rien loguer ; tout log doit être `Log.*` avec event `StaticString` littéral).
2. Lancer la suite de tests. Aucune régression attendue (l'init `OnboardingWindow` a gagné des paramètres mais reste construit uniquement par `makeOnboardingWindow`, non testé directement). Si un test échoue à cause d'un symbole renommé/supprimé, restaurer la compat (ne pas renommer de type public consommé ailleurs).
  </action>
  <verify>
    <automated>cd Souffleuse && ./audit.sh && swift test 2>&1 | tail -25</automated>
  </verify>
  <done>`audit.sh` passe (invariants privacy intacts). `swift test` vert (aucune régression). Build app possible (`make-app.sh` non requis ici — l'orchestrateur fera le test live).</done>
</task>

</tasks>

<verification>
- `swift build` compile après chaque tâche.
- `audit.sh` passe (no print/NSLog, log events StaticString uniquement, invariants privacy intacts).
- `swift test` vert (~640 @Test).
- Override dev : `SOUFFLEUSE_ONBOARDING=1` force l'affichage ; `=fresh` repart de l'étape 1 (clé reprise effacée).
- Complétion (`onboardingCompletedVersion`) écrite SEULEMENT via `onFinished`, jamais à l'ouverture.
- Étapes intermédiaires : pied Retour/Continuer FIXE hors ScrollView ; permissions gatées sur AX + Surveillance.
</verification>

<success_criteria>
- L'onboarding est un wizard multi-étapes (welcome → permissions → language → voice → howItWorks → done), DA Souffleuse conservée, copy française non-technique.
- Cartes de permission à état live (poll 1 s) avec prompts directs + fallback Réglages + encart d'aide repliable couvrant les pépins courants.
- Complétion à la fin + reprise d'étape (`onboardingProgressStep`) survivant à un relancement forcé par macOS.
- Rétrocompat : ancien utilisateur (`onboardingDone` + AX + ghost) ne revoit pas l'onboarding.
- `swift build`, `audit.sh`, `swift test` tous verts.
</success_criteria>

<output>
After completion, create `.planning/quick/260612-gto-refonte-onboarding-en-wizard-multi-tapes/260612-gto-SUMMARY.md`
</output>
