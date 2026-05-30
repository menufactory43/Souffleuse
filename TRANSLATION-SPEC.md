# TRANSLATION-SPEC — Traduction temps-réel « deux fantômes »

> Spec d'implémentation pour la feature de traduction live de Souffleuse (assistant
> de frappe local-LLM macOS, French-first, usage Waltio dans Intercom via Brave).
> Branche de départ recommandée : `feat/translation-hud` à partir de `feat/ghost-v2`.
>
> **VÉRITÉ TERRAIN** (le `CLAUDE.md` archi est PÉRIMÉ sur ces points) :
> - Le moteur LIVE est **llama.cpp** (`Sources/SouffleuseLlama/LlamaEngine.swift`),
>   pas MLX. MLX survit uniquement pour le tokenizer n-gram (best-effort).
> - Le ghost FR utilise un GGUF **base/pt** Gemma 3 1B, prompt **brut** (pas de
>   chat-template).
> - **427 tests** doivent rester verts (le « 94 » du CLAUDE.md est faux).
> - `audit.sh` doit rester vert : pas de `print`/`NSLog`/`os_log` interpolant du
>   texte user dans les cibles SHIPPING ; champs de log whitelistés
>   `{ts,level,module,event,count}` ; `history.db` lu seulement dans
>   Personalization + HistoryViewer.

---

## 1. Design verrouillé (résumé exécutif)

Décisions déjà prises — **ne pas redébattre**, la spec en évalue le COMMENT.

- **Deux fantômes simultanés et indépendants :**
  1. **Ghost FR inline** = l'autocompléteur actuel, **strictement inchangé**.
     Continuation française au caret via le moteur base Gemma 3 1B (llama.cpp).
     Accept = touche **⇥**. Rôle : vitesse de frappe.
  2. **HUD cible** = NOUVEAU. Panneau flottant `NSPanel` non-activating, **séparé
     du textarea**, qui traduit la phrase **ACCEPTÉE** (texte réel du champ via AX,
     PAS la prédiction spéculative) dans la langue du client.

- **HUD :** docké à **droite** du champ par défaut (sur la zone détails Intercom),
  **déplaçable** par une poignée, position **mémorisée par app (bundleID)**.
  Ancrage **relatif** au cadre du champ `{bord, écart}`, jamais absolu. Suit le
  **rect du champ** (`AXSnapshot.elementRect`), pas le caret → ne tremble pas.

- **Cible AUTO :** détectée depuis le message entrant du client (langue) ; chip
  **FR→XX** override en 1 clic, **collant par conversation**.

- **Confiance, deux mécanismes GRATUITS (une seule passe de génération) :**
  - **B** = surligner les tokens cible à faible logprob.
  - **C** = garde-fou « les termes métier / noms / chiffres ont-ils survécu »
    (règle sur tokens, **zéro LLM**). PAS de rétro-traduction permanente.

- **Deux touches :** **⇥** accepte le ghost FR ; **⌘↩** (configurable, pattern
  `AcceptAllKey`) « commit » = remplace la ligne FR par la cible, prêt à envoyer.

- **Deux moteurs :** ghost FR = base (existant, `ModelRuntime.llamaEngine`).
  Traduction = **2e `LlamaEngine` INSTRUCT paresseux** (`gemma-3-1b-it`,
  chat-template Gemma), chargé au 1er usage. Raison : Gemma 1B base n'est pas un
  bon traducteur.

**Invariants à préserver :** `audit.sh` vert · 427 tests verts · 100% on-device
(aucun réseau runtime sauf 1er download modèle) · Swift 6 strict concurrency ·
plancher TTFT du ghost FR = baseline commit `6ad70df`.

---

## 1bis. Résultats du gate Phase 0 (MESURÉS — `feat/translation-gate`, commit `eec719f`)

Bench `SouffleuseTranslateBench` exécuté sur la machine cible (8 Go RAM, swap
saturé), `gemma-3-1b-it-Q4_K_M` (769 Mo), 10 phrases support Waltio × 5 langues.

**Décisions verrouillées par la mesure :**
- **Modèle V1 = `gemma-3-1b-it`** (Q4_K_M). TTFT médian **71 ms**, débit **77
  tok/s** (réutilisation KV du préfixe instruct stable) → **caveat latence FERMÉ**.
- **Langues V1 = EN, ES, DE, IT.** **JA hors V1** (hallucinations : « BNB smart
  contract » inventé, « déclaration » laissé en français). EN solide, ES bon,
  DE/IT corrects mais faillibles.
- **Garde-fou C remonté en V1** (était Phase 6). Justifié par des ratés RÉELS du
  1B-it : nombre corrompu (`1 250,50 €` → `250,50 €` en DE), clause laissée en
  français (IT #9). C = filet non négociable, pas un enrichissement.
- **Mémoire :** `phys_footprint` sous-estime (poids **mmap** file-backed). Le coût
  *dirty* marginal d'un 2ᵉ moteur ≈ **70 Mo** (KV + compute) ; les poids mmap sont
  **évictables** (re-lus du disque). → **Défaut confirmé : 2ᵉ `LlamaEngine`
  instruct paresseux** (coexistence viable, coût dirty faible). **Fallback
  documenté : moteur unique + swap `modelPath`** si le thrash disque se révèle
  pénalisant en usage réel sur 8 Go (le swap a grossi de 14→16 Go pendant le test).
- **B (logprobs)** reste l'**unique enrichissement différé** (après le cœur V1).

→ Ces résultats modifient le plan §4 : **C entre dans le cœur V1**, **JA exclu**.

---

## 2. Architecture composant par composant

Pour chaque composant : fichier(s) réel(s), ce qui change, point d'intégration
(`fichier:ligne` quand connu).

### 2.1 — 2e moteur instruct (traduction) + logprobs par-token

**Fichiers :**
- `Souffleuse/Sources/SouffleuseLlama/LlamaEngine.swift` (MODIFIÉ)
- `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` (MODIFIÉ ou nouveau `TranslationRuntime`)
- `Souffleuse/Sources/Souffleuse/GGUFModelOption.swift` (MODIFIÉ — entrée instruct)

**Ce qui change :**

- **2e instance `LlamaEngine` paresseuse.** Le `LlamaEngine` est un `actor`
  (`LlamaEngine.swift:361`), `init() {}` vide (`:443`), `load(modelPath:)`
  idempotent `@discardableResult` (`:464`), `unload()` existant, et
  `backendOnce` (`:435`) garantit l'init backend process-wide → **deux instances
  cohabitent proprement**, chacune avec son propre KV-cache (`kvTokens`, `:384`)
  et ses caches de bans (`:402-420`). On ajoute, à côté de
  `ModelRuntime.llamaEngine` (`ModelRuntime.swift:90`) :
  ```swift
  let actionEngine = LlamaEngine()
  private(set) var actionReady = false
  ```
  Le chargement se fait **au 1er ⌘↩ commit** (lazy), pas dans `loadModel()`.

- **Path instruct.** Ajouter une entrée `GGUFModelOption` dédiée (id
  `gemma-3-1b-it-q4`, `fileName: "gemma-3-1b-it.Q4_0.gguf"`) au catalogue
  (`GGUFModelOption.swift:78-93`) OU un helper de résolution séparé qui n'apparaît
  PAS dans le picker user du ghost. La résolution réutilise
  `GGUFModelOption.resolvePath(fileName:)` (`:41`) → env `SOUFFLEUSE_GGUF` >
  `~/.../Souffleuse/Models` > `~/.../Cotypist/Models`. Prévoir l'état
  « fichier introuvable » comme le picker (`isResolvable`, `:37`).

- **Logprobs par-token (mécanisme B).** Aujourd'hui la closure publique
  `generate(prompt:maxTokens:sampling:onToken:)` (`:787-793`) ne transporte
  **que le `String` piece** ; le mécanisme softmax existe DÉJÀ
  (`LlamaEngine.swift:1103-1116`) mais **seulement pour le premier token** et
  stocké dans `metrics.firstTokenProb`. Pour B :
  - **Ajouter une SURCHARGE distincte** (ne PAS muter la closure existante —
    évite de casser `generateLlama` + les 7 benches/probes + le test
    `KVCacheReuseTests:122` qui passe `{ _ in … }`) :
    ```swift
    @discardableResult
    public func generate(
        prompt: String,
        maxTokens: Int,
        sampling: LlamaSampling = LlamaSampling(),
        onTokenDetailed: @Sendable (String, Double) -> Bool   // (piece, logprob)
    ) -> LlamaMetrics
    ```
  - Corps quasi-verbatim de `generate`, avec le bloc softmax (`:1106-1113`)
    **déplacé DANS la boucle** (sans le garde `produced == 0`), calculant
    `logprob = ln(prob)` pour le token choisi à CHAQUE itération.
  - **Optimisation SIMD obligatoire dès le départ** : `vDSP_maxv` est déjà
    importé/utilisé (`:1059`) ; calculer `sumExp` via `vvexpf` + `vDSP_sve`. NE
    PAS expédier le scan Swift naïf par-token (`~15-20 ms/step` sur vocab Gemma
    3 ~262k → inacceptable même hors ghost ; `< 1 ms` avec vDSP).
  - Le `logprob` (Double) est **copié avant** de quitter la closure `@Sendable`
    (le pointeur `llama_get_logits_ith` ne survit pas hors boucle, `:1104`).
  - **Câbler `onTokenDetailed` UNIQUEMENT sur `actionEngine`** ; le ghost FR
    reste sur l'ancienne closure (zéro coût softmax par-token sur le chemin
    frappe-par-frappe).

**Points d'intégration :** `ModelRuntime.swift:90` (sibling engine),
`LlamaEngine.swift:787` (surcharge), `GGUFModelOption.swift:78` (entrée instruct).

---

### 2.2 — Builder chat-template Gemma (instruct)

**Fichiers :**
- `Souffleuse/Sources/SouffleuseCore/GemmaChatPrompt.swift` (NOUVEAU)
- Référence : `Souffleuse/Sources/SouffleuseLlamaProbe/main.swift:378` (le SEUL
  endroit où le template Gemma est écrit en dur, hors audit).

**Ce qui change :**

- Le `LlamaEngine.generate` reste **prompt-brut** : le chat-template se construit
  **côté appelant** comme une `String`, comme le probe :
  ```swift
  "<start_of_turn>user\n\(contenu)<end_of_turn>\n<start_of_turn>model\n"
  ```
  `tokenize(addSpecial: true)` (`LlamaEngine.swift:796`) ajoutera le BOS Gemma.
- **NE PAS réutiliser `LlamaPromptBuilder.buildLlamaPrompt`** (conçu pour le
  base/pt brut, refuse explicitement le chat-template — doc `LlamaPromptBuilder`).
  Créer un type dédié `GemmaChatPrompt` (enum, pure-functions, `Sendable`) :
  - `buildTranslation(source:targetLanguage:examples:[String]) -> String`
  - Le bloc système instruit la traduction (registre support, préserver
    termes/noms/chiffres). Few-shot de **style** optionnel (cf. §2.7).
  - **Le texte FR à traduire est placé STRICTEMENT EN DERNIER** dans le contenu
    user (maximise la réutilisation KV-cache LCP `:852-882` : le préfixe
    système + exemples par langue est STABLE → LCP réutilisé entre traductions).

---

### 2.3 — Lecture AX du cadre champ / texte / sélection + remplacement (commit)

**Fichiers :**
- `Souffleuse/Sources/SouffleuseAX/AXClient.swift` (MODIFIÉ — minimal)

**Ce qui existe DÉJÀ (réutiliser tel quel) :**
- `AXSnapshot.elementRect: CGRect?` (`:22`), rempli par `readElementRect(_:)`
  (`:707-719`) en coordonnées **Quartz** (top-left). C'est l'ancre du HUD. Marche
  en Chromium/Brave (ne dépend pas de NSRange). Déjà consommé à
  `SouffleuseAppDelegate.swift:656`/`:814`.
- `AXSnapshot.text` (kAXValueAttribute, `:429`) = valeur complète du champ →
  **la phrase à traduire** (suffisant pour Intercom, pas besoin de la sélection
  en V1).
- `inject(_:)` (`:188-220`) : insère au caret / remplace la sélection, refuse les
  `AXSecureTextField` (`:199-202`), fallback `injectViaCGEvent` universel.
- `replaceTrailing(deleteChars:with:)` (`:233-239`) : N backspaces CGEvent +
  insert (chemin éprouvé Brave, `:244`).

**Ce qui change (commit ⌘↩, swap ligne FR → cible) :**
- Le code AVERTIT (`:222-232`) que l'écriture `kAXSelectedTextRangeAttribute`
  renvoie `.success` mais est ignorée par Notes/RichText → **ne pas s'y fier**.
- **Réutiliser `replaceTrailing(deleteChars: lineFR.count, with: cible)`** : lire
  `snap.text`, supprimer sa longueur, insérer la cible. Chemin CGEvent = le plus
  robuste cross-host (verdict adverse : `feasible`).
- Hériter du **garde secure-field** (`:199-202`) : pas de traduction d'un mot de
  passe.
- Reproduire le settle `usleep(5_000)` (`:248`) pour le commit.

**Optionnel V2 (traduire une sélection partielle) :** `readCaret` lit déjà
`cfRange.length` (`:542`, jeté) ; ajouter `selectedText: String?` +
`selectedRange: NSRange?` à `AXSnapshot` (init a tous params à defaults → ajout
**non-breaking**) via `stringForRange` (`:689-703`). Hors V1.

**Concurrence :** toute nouvelle méthode AX DOIT s'exécuter dans `queue.sync`
(`:87`) — `AXClient` est `@unchecked Sendable`, sûreté = sérialisation seule.

**Points d'intégration :** `AXClient.swift:233` (`replaceTrailing`),
`AXClient.swift:707` (`elementRect`).

---

### 2.4 — Touche commit ⌘↩ (KeyInterceptor + dispatch)

**Fichiers :**
- `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift` (MODIFIÉ)
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (MODIFIÉ)
- `Souffleuse/Sources/Souffleuse/PreferencesStore.swift` (MODIFIÉ)
- `Souffleuse/Sources/Souffleuse/PreferencesWindow.swift` (MODIFIÉ)

**Ce qui change :**
- `KeyInterceptor.Key` (`:50-54`) → ajouter `case commit`.
- Nouvel `enum CommitKey: String, CaseIterable, Sendable` **miroir d'`AcceptAllKey`**
  (`:20-47`), preset `cmdReturn` : `keyCode = 36`,
  `requiredFlagsRaw = CGEventFlags.maskCommand.rawValue`, label `"⌘↩ Cmd+Entrée"`.
- Nouveau lock **distinct** `commitBinding = OSAllocatedUnfairLock<(code,flagsRaw)?>`
  (ne PAS surcharger `acceptBinding` `:73` — les deux touches coexistent) +
  `setCommitKey(_:)` calqué sur `setAcceptAllKey` (`:131`).
- Dans `handle()` (`:159`) : tester `commitBinding` **AVANT** `acceptBinding`
  (priorité au plus spécifique). `relevant` inclut déjà `maskCommand` (`:152-153`)
  → ⌘↩ matche `keyCode==36 && mods==maskCommand`, distinct du `returnKey` nu
  (`mods==0`).
- `SouffleuseAppDelegate` : `case .commit:` dans `handleKey()` (`:1183`) → lit la
  ligne FR via AX, la remplace par la cible HUD, teardown. Respecter le hop
  `MainActor.assumeIsolated` / `DispatchQueue.main.async` (`:229`, `:1413`) —
  `handleKey` est `nonisolated` sur le thread du tap.
- `interceptor.setCommitKey(store.commitKey)` au boot (`:235`) + au changement de
  prefs (`:423`) + `_ = store.commitKey` dans `withObservationTracking` (`:390`).
- `PreferencesStore` : `K.commitKey` (`:135`), `var commitKey: CommitKey { didSet … }`
  (`:195`), défaut `.cmdReturn` (`:247`).
- `PreferencesWindow` : dupliquer le Picker (`:257-263`) pour `$store.commitKey`.

**PIÈGE CENTRAL — activation du tap.** Le tap n'est ACTIF que pendant qu'un ghost
FR s'affiche (`setActive(true)` à `:987/999/1112/1178`). Si le HUD cible peut
exister **sans** ghost FR inline, ⌘↩ ne sera jamais intercepté → Intercom enverra
le message. **Il faut élargir la condition `setActive(true)` pour inclure « HUD
cible affiché ».** (Voir §4 Phase 5, §5 risque dédié.)

---

### 2.5 — HUD : `TranslationOverlayWindow` (NSPanel interactif)

**Fichiers :**
- `Souffleuse/Sources/SouffleuseOverlay/TranslationOverlayWindow.swift` (NOUVEAU)
- `Souffleuse/Sources/SouffleuseOverlay/TranslationHUDView.swift` (NOUVEAU — vue multi-rangées)
- Référence : `PresenceIndicatorWindow.swift` (ancré au **cadre du champ**, le bon patron)

**Ce qui change :**
- Cloner la topologie `NSPanel` de `PresenceIndicatorWindow.swift:21-34`
  (`[.borderless, .nonactivatingPanel]`, `level .statusBar`, `isFloatingPanel`,
  `collectionBehavior` identique, `orderFrontRegardless` — **jamais `makeKey`**),
  **MAIS** :
  - `panel.ignoresMouseEvents = false` (le HUD reçoit le drag poignée + le clic chip).
  - `becomesKeyOnlyIfNeeded = true` + sous-classe `NSPanel` override
    `canBecomeKey = false`, `canBecomeMain = false` (ceinture+bretelles : le champ
    de l'app sous-jacente garde le focus clavier — verrou décisif, verdict
    adverse `feasible`).
  - **`styleMask` figé à l'init** (jamais muté après — évite le bug
    nonactivating connu).
- **Drag de la poignée** : sous-vue dédiée override `mouseDown(with:)` →
  `self.window?.performWindowDragWithEvent(event)`. NE PAS utiliser
  `isMovableByWindowBackground` (combattrait le hit-test du chip). Override
  `hitTest` sur la contentView : ne renvoyer une vue que sur les rects
  **poignée + chip**, `nil` ailleurs (click-through sur le reste, ne masque pas
  Intercom).
- **Multi-rangées** : contentView = `NSStackView` verticale :
  - Rangée cible = `NSTextView`/`NSAttributedString` (surlignage B par-token :
    background/foreground sur les ranges des tokens faible-logprob).
  - Rangée chip `FR→XX` cliquable (override de cible).
  - Rangée garde-fou C (badge « termes vérifiés » / liste des manquants).
- **Ancrage** : réutiliser la formule Quartz→AppKit de `PresenceIndicatorWindow.show(at:)`
  (`:47-50`) mais docker à **droite** : `appKitX = fieldRectQuartz.maxX + gap`.
  Rejouer l'offset `{bord, écart}` relatif au rect courant à chaque tick.
- **Anti-shimmer** : garde de redondance (skip `setFrame` si rect/contenu
  inchangés, cf. `OverlayWindow.show:93`). **Pendant un drag, suspendre le
  re-anchoring auto** (sinon le tick 80 ms ramène le HUD sous le doigt).
- `@MainActor public final class` (AppKit). Le streaming de traduction arrive sur
  un Task → `await MainActor.run { hud.update(...) }`. NSFont/NSAttributedString
  non-`Sendable` → construire l'attributed string **sur le MainActor** à partir
  de `String` + ranges `Sendable`.

**Points d'intégration :** greffe juste après le bloc `presence.show(at:)`
(`SouffleuseAppDelegate.swift:813-823`), gardé par `snap.elementRect != nil` +
flag `hudEnabled`. `snap.bundleID` = clé par-app.

---

### 2.6 — Persistance position HUD par app : `HUDAnchorStore`

**Fichiers :**
- `Souffleuse/Sources/Souffleuse/HUDAnchorStore.swift` (NOUVEAU)
- Patron EXACT : `AllowlistConfig.swift` (triade type valeur / enveloppe versionnée / store)

**Ce qui change — cloner la triade `AllowlistConfig.swift` :**
```swift
enum HUDEdge: String, Codable, Sendable { case right, left, top, bottom }

struct HUDAnchor: Codable, Sendable {
    var bundleID: String
    var edge: HUDEdge = .right
    var offsetX: Double = 0
    var offsetY: Double = 0          // tous defaults → décodage tolérant
}

private struct HUDAnchorFile: Codable {
    var version: Int = 1
    var anchors: [HUDAnchor] = []
}

@MainActor @Observable final class HUDAnchorStore {
    private(set) var anchors: [HUDAnchor] = []
    @ObservationIgnored private let fileURL: URL
    convenience init() { … "hud-anchors.json" … }   // cf. AllowlistStore:52-57
    init(fileURL: URL) { self.fileURL = fileURL; load() }
    func load() { … reset à [] + Log.warn(.ui, "hud_anchor_load_corrupt_reset") … }
    func save() { … JSONEncoder [.prettyPrinted,.sortedKeys] atomic … }
    func anchor(forBundle:) -> HUDAnchor?      // wrapper instance
    func upsert(_:)                            // clé = bundleID (pas UUID)
    func reset(bundleID:)
    nonisolated static func anchor(forBundle:anchors:) -> HUDAnchor?  // lookup pur testable
}
```
- Fichier : `~/Library/Application Support/Souffleuse/hud-anchors.json`.
- Instanciation : `let hudAnchors = HUDAnchorStore()` à côté de
  `let allowlist = AllowlistStore()` (`PreferencesStore.swift:212`).
- **Lecture** au rendu : `prefs.hudAnchors.anchor(forBundle: snap.bundleID)` ;
  nil → défaut dock droite. **Écriture** en fin de drag.
- **Log :** réutiliser `.ui` (pas de `LogModule .hud`, `Log.swift:8`), event
  `StaticString` littéral, JAMAIS interpoler bundleID/coordonnées.

---

### 2.7 — Cible AUTO + langue + override collant par conversation

**Fichiers :**
- `Souffleuse/Sources/SouffleuseCore/LlamaPromptBuilder.swift` (réutilisé : `detectLanguage(in:)`)
- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift` (MODIFIÉ — conserver `enriched.visible`)
- `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift` (MODIFIÉ — budget détection)
- `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift` (MODIFIÉ — langues OCR / correction)
- `Souffleuse/Sources/Souffleuse/ConversationTargetStore.swift` (NOUVEAU — collant par conversation)

**Ce qui change :**
- **Détection langue cible** : réutiliser `LlamaPromptBuilder.detectLanguage(in:)`
  (`:46-75`, NLLanguageRecognizer, `count>=8` ET confiance `>=0.5`) sur le
  **message client**. Seule source = `EnrichedContext.visible` (OCR + nettoyé via
  `VisibleTextCleaner`). **Cesser de jeter `enriched.visible`** : aujourd'hui
  seul `enriched.prefix` est conservé (`SouffleuseAppDelegate.swift:882`).
- **Pour la détection seulement** : élargir à ~512 chars (cap actuel 240,
  `ContextEnricher.swift:16`) et **désactiver `usesLanguageCorrection`**
  (`VisionOCR.swift:103-105` force fr/en → falsifie le texte étranger). Activer
  `recognitionLanguages` élargi (de/it/pt/nl/es) quand la feature est ON.
- **Collant par conversation** : nouveau store `@MainActor @Observable`
  (`conversation-targets.json`, patron `AllowlistStore`). **Clé proxy** =
  `bundleID + cleanedWindowTitle` (pas d'ID conversation fiable en web). Algo de
  collance copié de `lastDetectedLanguage` (`PredictorViewModel.swift:474`) :
  détection confiante écrase, court/ambigu retombe sur la dernière cible OU
  l'override manuel.
- **Override chip FR→XX** : écrit dans le store, prioritaire sur l'AUTO.

**Verdict adverse (`risky`) :** la cible AUTO est **best-effort**, le chip est le
filet de **première classe**. Ne JAMAIS bloquer le commit sur la détection : si
cible inconnue, chip vide, l'utilisateur tranche en 1 clic. Fallback B (cf. §5) :
demander la langue via un mini-prompt au moteur instruct si NLLanguageRecognizer
échoue.

---

### 2.8 — Garde-fou C (termes/noms/chiffres survivants) + retrieval de style

**Fichiers :**
- `Souffleuse/Sources/SouffleuseCore/TermSurvivalGuard.swift` (NOUVEAU)
- `Souffleuse/Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift` (MODIFIÉ — seuils)
- `Souffleuse/Sources/SouffleusePersonalization/SimilarHistoryRetrieval.swift` (réutilisé pour le style)

**Ce qui change :**
- **Mécanisme C** = helper pur `Sendable` dans `SouffleuseCore` (à côté
  d'`OutputFilter`), **zéro appel LLM** : extrait de la source FR les tokens
  « durs » (chiffres, montants, %, noms propres capitalisés, termes métier d'une
  liste) et vérifie leur survie dans la cible. Retourne `[String]` manquants →
  badge HUD. **Tous les seuils** (liste termes, sensibilité) DOIVENT vivre dans
  `SuggestionPolicy+Tuning.swift` (Pitfall 6 : aucun littéral de seuil ailleurs).
- **Style (optionnel)** : `SimilarHistoryRetrieval.rank(entries:.prose, userTail: texteFR, limit:)`
  fournit des exemplars de **registre** (ton de Gabriel) injectés dans le prompt
  instruct via `GemmaChatPrompt` (format labellisé `FR: …\nXX: …` autorisé car
  modèle INSTRUCT, contrairement au base). **Pas de migration DB requise** pour
  le style-only (le sens vient du modèle, le style de l'injection — cohérent avec
  les findings handoff : le recall L1 ne généralise pas).

---

### 2.9 — Contention GPU & priorité du ghost FR

**Fichiers :**
- `Souffleuse/Sources/Souffleuse/ModelRuntime.swift` (MODIFIÉ — orchestration)
- `Souffleuse/Sources/SouffleuseLlama/LlamaEngine.swift` (MODIFIÉ — abort callback)

**Ce qui change (verdict adverse `risky`, pas blocker) :**
- Un seul `MTLCommandQueue` partagé Metal → les `llama_decode` des deux moteurs
  **sérialisent** sur le GPU, sans priorité native. `generate()` est une boucle
  **synchrone sans suspension** qui squatte un thread du pool coopératif.
- Mitigations :
  - Lancer la traduction sur `Task.detached(priority: .utility)` (ne pas voler un
    thread au ghost).
  - **GpuGate logiciel** : tant qu'un ghost est en vol, retarder le DÉMARRAGE de
    la traduction (le ghost est court ; la traduction « a le droit de traîner »).
  - **`llama_set_abort_callback`** sur `actionEngine` : si un nouveau ghost
    arrive pendant une traduction, l'abort coupe le décode GPU de la traduction
    (relançable, événement discret).
  - `n_threads` du moteur instruct réduit (ex. `cores/2`) pour éviter la
    sur-souscription CPU.
  - Préfixe instruct STABLE par langue → KV-cache LCP réutilisé (texte FR en
    dernier, §2.2).

---

## 3. Manifeste de fichiers

### NOUVEAUX fichiers

| Fichier | Type | Rôle |
|---|---|---|
| `Sources/SouffleuseCore/GemmaChatPrompt.swift` | enum pur | Chat-template Gemma instruct (build traduction) |
| `Sources/SouffleuseCore/TermSurvivalGuard.swift` | helper `Sendable` | Mécanisme C (garde-fou termes/chiffres) |
| `Sources/SouffleuseOverlay/TranslationOverlayWindow.swift` | `@MainActor` NSPanel | HUD flottant interactif |
| `Sources/SouffleuseOverlay/TranslationHUDView.swift` | NSView/NSStackView | Vue multi-rangées (cible + B + C + chip) |
| `Sources/Souffleuse/HUDAnchorStore.swift` | `@MainActor @Observable` | Position HUD par bundleID |
| `Sources/Souffleuse/ConversationTargetStore.swift` | `@MainActor @Observable` | Cible collante par conversation |
| `Sources/Souffleuse/TranslationViewModel.swift` | `@MainActor @Observable` | Cerveau du flux traduction (déclenché sur accept) |
| `Tests/SouffleuseTests/HUDAnchorStoreTests.swift` | Swift Testing | round-trip + corrupt-reset |
| `Tests/SouffleuseTests/GemmaChatPromptTests.swift` | Swift Testing | forme du chat-template, FR en dernier |
| `Tests/SouffleuseTests/TermSurvivalGuardTests.swift` | Swift Testing | survie chiffres/noms/termes |
| `Tests/SouffleuseTests/KeyInterceptorMappingTests.swift` | Swift Testing | mapping keyCode→Key (commit/acceptAll/tab) |

> **Décision de target** : pas de nouvelle lib `SouffleuseTranslate` requise. Le
> HUD vit dans `SouffleuseOverlay`, le prompt/guard dans `SouffleuseCore`, les
> stores + VM dans `Souffleuse`, le moteur réutilise `SouffleuseLlama`. **Si**
> une lib dédiée est créée plus tard, l'ajouter à `audit.sh` SHIPPING_DIRS
> (`:7-17`) — sinon elle échappe SILENCIEUSEMENT aux 6 checks privacy.

### Fichiers MODIFIÉS

| Fichier | Modification |
|---|---|
| `Sources/SouffleuseLlama/LlamaEngine.swift` | Surcharge `generate(...onTokenDetailed:)` + softmax par-token vDSP ; `llama_set_abort_callback` |
| `Sources/Souffleuse/ModelRuntime.swift` | `actionEngine` paresseux + `translate(...)` + GpuGate orchestration |
| `Sources/Souffleuse/GGUFModelOption.swift` | Entrée instruct `gemma-3-1b-it-q4` |
| `Sources/SouffleuseInput/KeyInterceptor.swift` | `Key.commit`, `CommitKey`, `commitBinding`, `setCommitKey`, test prioritaire |
| `Sources/Souffleuse/SouffleuseAppDelegate.swift` | Branche `.commit`, greffe HUD dans tick, conserver `enriched.visible`, élargir `setActive` |
| `Sources/SouffleuseAX/AXClient.swift` | (V2) `selectedText`/`selectedRange` ; commit via `replaceTrailing` (déjà présent) |
| `Sources/Souffleuse/PreferencesStore.swift` | `K.commitKey`, `commitKey`, `hudEnabled`, `let hudAnchors`, `let conversationTargets` |
| `Sources/Souffleuse/PreferencesWindow.swift` | Picker `commitKey` + toggle `hudEnabled` |
| `Sources/SouffleuseContext/ContextEnricher.swift` | Champ/budget détection langue (~512 chars non-cappés) |
| `Sources/SouffleuseContext/VisionOCR.swift` | `recognitionLanguages` élargi + correction OFF pour détection |
| `Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift` | Seuils C, ancrage HUD, longueur traduction |
| `Sources/SouffleuseCore/LlamaPromptBuilder.swift` | (réutilisé) `detectLanguage(in:)` exposé au flux cible |
| `audit.sh` | (si nouvelle lib) ajouter au SHIPPING_DIRS — sinon inchangé |

---

## 4. Plan phasé exécutable

> Chaque phase garde **427 tests verts** + **`audit.sh` vert**. Valeur livrée tôt.
> Ordre conçu pour dé-risquer (qualité modèle d'abord) avant de construire l'UI.

### Phase 0 — Gate qualité & mémoire (PROTOTYPE hors audit) — ✅ **FAIT** (`eec719f`, voir §1bis)
- **Objectif :** valider AVANT toute UI que `gemma-3-1b-it` traduit FR→DE/EN/ES/IT
  (et JA best-effort) de façon acceptable, ET mesurer le coût mémoire de 2 modèles
  1B sur la machine cible (8 Go RAM, swap déjà saturé).
- **Fichiers :** nouveau bench `Sources/SouffleuseTranslateBench/main.swift` (cible
  SwiftPM dev, **hors audit**, `print()` libre) ; télécharger un GGUF instruct
  (tokens `<start_of_turn>`/`<end_of_turn>` en CONTROL — issue conversion connue).
- **Done :** 20-30 phrases support Waltio réelles traduites + jugées ; `vmmap
  --summary <pid>` à 2 modèles mesuré ; TTFT ghost vérifié sous plancher `6ad70df`.
- **Risque :** ⚠️ **gate go/no-go**. Si JA inacceptable → restreindre V1 aux
  langues proches. Si double-load sature → fallback mémoire (§5).

### Phase 1 — 2e moteur instruct + chat-template (sans UI)
- **Objectif :** `ModelRuntime.actionEngine` paresseux + `GemmaChatPrompt` + une
  méthode `translate(text:targetLanguage:) -> AsyncStream<String>`.
- **Fichiers :** `ModelRuntime.swift`, `LlamaEngine.swift` (load réutilisé),
  `GemmaChatPrompt.swift`, `GGUFModelOption.swift`.
- **Done :** un test unitaire `GemmaChatPromptTests` (forme template, FR en
  dernier) ; un bench dev appelle `translate` et stream. `audit.sh` vert.
- **Risque :** faible (le moteur est éprouvé, 2e instance mécaniquement sûre).

### Phase 2 — Touche commit ⌘↩ + remplacement AX
- **Objectif :** ⌘↩ configurable remplace la ligne FR par une string fixe (cible
  factice d'abord), via `replaceTrailing`. Pas encore de traduction live.
- **Fichiers :** `KeyInterceptor.swift`, `SouffleuseAppDelegate.swift`,
  `PreferencesStore.swift`, `PreferencesWindow.swift`.
- **Done :** `KeyInterceptorMappingTests` (commit/acceptAll/tab) ; ⌘↩ remplace en
  Brave/Notes ; garde secure-field OK. `audit.sh` vert.
- **Risque :** moyen (activation du tap sans ghost — voir Phase 5).

### Phase 3 — `HUDAnchorStore` + `TranslationOverlayWindow` statique
- **Objectif :** HUD docké à droite du champ (texte statique), ancré à
  `elementRect`, position mémorisée par app, drag de la poignée.
- **Fichiers :** `HUDAnchorStore.swift`, `TranslationOverlayWindow.swift`,
  `TranslationHUDView.swift`, `SouffleuseAppDelegate.swift` (greffe tick),
  `PreferencesStore.swift` (`hudEnabled`, `let hudAnchors`).
- **Done :** `HUDAnchorStoreTests` (round-trip + corrupt-reset) ; HUD suit le
  champ sans trembler ; drag persiste l'ancre ; click-through hors poignée/chip.
  `audit.sh` vert.
- **Risque :** moyen (focus clavier pendant drag — mitigé `nonactivatingPanel` +
  `canBecomeKey=false`).

### Phase 4 — Flux traduction live (commit → HUD)
- **Objectif :** sur ⌘↩ accept, lire `snap.text` (texte réel), streamer la
  traduction dans le HUD, puis remplacer la ligne FR par la cible.
- **Fichiers :** `TranslationViewModel.swift`, `SouffleuseAppDelegate.swift`
  (greffe sur `performFullAccept`/branche `.tab` full-accept post-inject,
  `:1335/:1456`), `TranslationOverlayWindow.swift` (update streaming).
- **Done :** traduction réelle affichée + commit fonctionnel ; déclenché sur
  événement **accept** (pas spéculatif). `audit.sh` vert (aucun texte loggé).
- **Risque :** moyen (concurrence Task→MainActor, hoister les valeurs `Sendable`).

### Phase 5 — Cible AUTO + chip override collant + GpuGate
- **Objectif :** détecter la langue client (OCR `enriched.visible`), chip FR→XX
  collant par conversation, GpuGate + abort callback pour la priorité ghost,
  élargir `setActive` au HUD.
- **Fichiers :** `ConversationTargetStore.swift`, `SouffleuseAppDelegate.swift`,
  `ContextEnricher.swift`, `VisionOCR.swift`, `LlamaPromptBuilder.swift`,
  `ModelRuntime.swift` (GpuGate), `LlamaEngine.swift` (abort).
- **Done :** cible auto pré-remplie quand confiance OK, sinon chip vide ; ghost
  TTFT non régressé pendant une traduction (mesuré). `audit.sh` vert.
- **Risque :** ⚠️ `risky` (détection OCR fragile + contention GPU — mitigations §5).

### Phase 6 — Confiance B (logprobs)  *(C est désormais en V1, cf. §1bis — intégré au flux dès Phase 4/5)*
- **Objectif :** surlignage tokens faible-logprob (B). Le garde-fou C (survie
  termes/chiffres + détection de non-traduction) est implémenté plus tôt, avec le
  flux de traduction, car le gate a montré qu'il attrape des ratés réels du 1B-it.
- **Fichiers :** `LlamaEngine.swift` (surcharge `onTokenDetailed` + softmax vDSP),
  `TranslationOverlayWindow.swift`/`TranslationHUDView.swift` (rendu),
  `TermSurvivalGuard.swift`, `SuggestionPolicy+Tuning.swift` (seuils).
- **Done :** `TermSurvivalGuardTests` ; B prototypé d'abord au bench dev (plage de
  logprobs utile) ; surlignage visible ; aucun logprob/texte loggé. `audit.sh` vert.
- **Risque :** faible-moyen (B mécaniquement à portée, coût softmax maîtrisé vDSP ;
  fallback marge-logit si trop lourd, §5).

### Phase 7 — Mémoire & polish
- **Objectif :** unload `actionEngine` à l'idle (N s d'inactivité HUD), états UI
  « pas de message lisible / fichier modèle introuvable », opt-in capture écran.
- **Fichiers :** `ModelRuntime.swift` (`unload` timer), HUD, `PreferencesWindow.swift`.
- **Done :** footprint borné mesuré ; feature complète. `audit.sh` + 427 tests verts.
- **Risque :** faible.

---

## 5. Registre de risques

### 🟡 RISKY (le plus structurant) — Qualité 1B-it + mémoire 2× 1B sur 8 Go
- **Preuve :** modèle instruct ABSENT du disque (seuls 2 GGUF base présents).
  Machine = 8 Go RAM, `vm.swapusage` déjà ~12.5 Go used. Un 1B Q5 ≈ 1.0 Go
  résident ; deux ≈ 2.0-2.5 Go. WMT24++ Gemma 3 1B = 36.7 (fonctionnel mais
  faible, JA distant à risque) ; instruct nettement > base pour tâche-à-instruction.
- **Mitigation retenue :** **Phase 0 = gate go/no-go.** Lazy-load + **unload à
  l'idle** (Phase 7). Q4_0 instruct (~720 Mo) plutôt que Q5. Restreindre V1 aux
  langues proches (FR→EN/DE/ES/IT) si JA inacceptable.
- **Plan B :** utiliser le `gemma-3-4b.i1-Q4_K_M.gguf` DÉJÀ présent (WMT24++ 48.4,
  vrai multilingue) comme moteur traduction **unique**, en swappant le `modelPath`
  d'un SEUL `LlamaEngine` (base ghost ↔ instruct/4B traduction) via `load()`
  idempotent → élimine la coexistence 2-modèles au prix d'un reload (~centaines de
  ms) au passage, acceptable car le commit est un événement discret.

### 🟡 RISKY — Contention GPU / priorité du ghost FR
- **Preuve :** un seul `MTLCommandQueue` Metal partagé ; `generate()` boucle
  synchrone sans suspension ; 2×(cores-1) threads CPU.
- **Mitigation retenue :** `Task.detached(.utility)` + **GpuGate** (retarder le
  démarrage traduction tant qu'un ghost est en vol) + `llama_set_abort_callback`
  (couper la traduction si un ghost arrive) + KV-cache LCP stable (texte FR en
  dernier) + `n_threads` réduit côté instruct. **Mesurer** TTFT ghost seul vs
  pendant traduction avant de figer.
- **Plan B :** sérialisation stricte « pause ghost pendant traduction » (en
  pratique au commit le ghost est déjà teardown). Plan C : `n_gpu_layers=0`
  (instruct sur CPU) → élimine TOUTE contention GPU, traduction plus lente
  (tolérable, « le HUD a le droit de traîner »).

### 🟡 RISKY — Fiabilité de la cible AUTO (détection OCR)
- **Preuve :** AX ne lit PAS le message client (focus seul) ; seul canal = OCR via
  `ContextEnricher` (capture écran OFF par défaut + TCC). OCR calibré fr/en
  (`usesLanguageCorrection=true`) → falsifie le texte étranger. NLLanguageRecognizer
  peu fiable sur texte court. `.visible` mélange tours + chrome UI FR.
- **Mitigation retenue :** AUTO = **best-effort**, chip override = **première
  classe**. Conserver `enriched.visible` (ne plus le jeter, `:882`), passe
  détection dédiée ~512 chars sans correction, langues OCR élargies. Collance par
  `bundleID+windowTitle`. Ne JAMAIS bloquer le commit sur la détection.
- **Plan B :** détection assistée par le moteur instruct (mini-prompt « code ISO
  de la langue ? ») sur le texte OCR — plus robuste sur texte court. Plan C :
  désactiver AUTO si OCR indisponible, exposer seulement le chip manuel (FR/EN/ES).

### 🟢 FEASIBLE — Logprobs par-token (mécanisme B)
- **Preuve :** softmax complète déjà calculée pour le first-token
  (`LlamaEngine.swift:1103-1116`) ; `llama_get_logits_ith` accessible dans la
  boucle (`:1104`) ; `vDSP_maxv` déjà importé (`:1059`).
- **Mitigation :** surcharge `onTokenDetailed` distincte (ne casse pas l'API
  existante ni les 7 benches ni `KVCacheReuseTests`) ; softmax par-token vDSP ;
  logprob copié avant de quitter la closure `@Sendable` ; prototyper au bench.
- **Plan B :** approximer par la **marge logit** `logits[tokenId]-topLogit`
  (un seul `vDSP_maxv`, pas de `sumExp`). Plan C : livrer C seul, différer B.

### 🟢 FEASIBLE — NSPanel déplaçable sans voler le focus clavier
- **Preuve :** `[.borderless,.nonactivatingPanel]` (panel peut recevoir
  souris/clavier sans activer son app) ; `becomesKeyOnlyIfNeeded` ;
  `performWindowDragWithEvent` (window-server, pas de transition key).
- **Mitigation :** topologie `PresenceIndicatorWindow` + `ignoresMouseEvents=false`
  + `canBecomeKey=false` + drag via `performWindowDragWithEvent` + `hitTest`
  limité poignée/chip + `styleMask` figé à l'init.
- **Plan B :** drag manuel `setFrameOrigin` dans `mouseDragged`. Plan C : 3-4
  positions d'ancrage discrètes via menu du chip (zéro `mouseDragged`).

### 🟢 FEASIBLE — Remplacement AX en Chromium/Brave (commit)
- **Preuve :** écriture `kAXSelectedTextRangeAttribute` cassée en Chromium ; mais
  `replaceTrailing` CGEvent (`:233`) éprouvé Brave, `inject` ghost live en Brave
  (`AppDelegate:1454`), `kAXValue` lisible (`:429`).
- **Mitigation :** réutiliser `replaceTrailing(deleteChars:with:)` off-main, garde
  secure-field, settle 5 ms. Plan B : `Cmd+A` puis inject, ou clipboard
  save/restore + `Cmd+V` ; jamais d'écriture AX.

### ⛔ BLOCKER ? — **AUCUN blocker dur identifié.**
Le seul risque potentiellement bloquant est la **qualité 1B-it sur langues
distantes (JA)** combinée à la **pression mémoire 8 Go**. Il est **désamorcé par
Phase 0 (gate)** et par les plans B (4B unique en swap, ou périmètre langues
proches). La feature reste livrable (HUD + commit + traduction langues proches)
même dans le pire cas.

---

## 6. Plan tests & invariants

### Nouveaux tests (Swift Testing dominant — `import Testing`, `@Suite/@Test/#expect`)
- `HUDAnchorStoreTests` : `hudAnchorRoundTripsToDisk` + `hudAnchorCorruptFileResetsToEmpty`
  (clone `allowlistRoundTripsToDisk:325` / `allowlistCorruptFileResetsToEmpty:353`,
  `@MainActor @Test`, fichier temp + `defer` cleanup).
- `GemmaChatPromptTests` : structure `<start_of_turn>user…model`, texte FR
  strictement en dernier, échappement.
- `TermSurvivalGuardTests` : chiffres/montants/%/noms propres détectés et survie
  vérifiée ; cas « tout survit » et « terme manquant ».
- `KeyInterceptorMappingTests` : extraire la fonction de mapping `keyCode+mods→Key`
  en **pure-function testable** (aujourd'hui 0 test sur `handle`), couvrir
  commit/acceptAll/tab/esc et la priorité commit > acceptAll.
- Le `ConversationTargetStore` : round-trip + collance (détection écrase, ambigu
  retombe).

### audit.sh reste vert
- Aucun `print(`/`NSLog`/`os_log` interpolant texte user dans les SHIPPING_DIRS.
- **JAMAIS logger** : texte traduit, langue cible, contenu du champ, logprob,
  termes, bundleID, coordonnées. Tout `Log.*` = `StaticString` littéral + champs
  `{ts,level,module,event,count}`. Réutiliser `.ui`/`.overlay`/`.input` (pas de
  nouveau `LogModule`). Compteurs neutres seulement (`count: nbAncres`, jamais une
  coordonnée).
- Prototypage de B/C dans les **benches dev** (hors audit, `print` libre) avant de
  toucher le shipping.
- Si une lib `SouffleuseTranslate` est créée : **l'ajouter au SHIPPING_DIRS**
  (`audit.sh:7-17`) — une lib non listée échappe SILENCIEUSEMENT aux checks.

### Concurrency Swift 6 (strict)
- `LlamaEngine` = `actor` → tout accès `await` ; `onTokenDetailed` reste
  `@Sendable` ; logprob `Double` copié avant la frontière ; pointeurs llama
  jamais hors boucle.
- HUD/stores `@MainActor` ; valeurs traversant le Task détaché = `Sendable`
  (hoister AVANT le Task `[weak self]`, comme `proseExamplesPool` PVM:538).
- `NSFont`/`NSAttributedString` non-`Sendable` → construits sur le MainActor à
  partir de `String` + ranges `Sendable`.
- Toute méthode AX dans `queue.sync` (`AXClient` `@unchecked Sendable`).
- `KeyInterceptor` : `commitBinding` = `OSAllocatedUnfairLock` distinct ; branche
  `.commit` via `MainActor.assumeIsolated`/`DispatchQueue.main.async`.

---

## 7. Décisions ouvertes (à trancher par l'utilisateur)

1. **Modèle de traduction.** ✅ **RÉSOLU par le gate (§1bis)** : `gemma-3-1b-it`
   Q4_K_M, 2ᵉ moteur paresseux (coexistence, coût dirty ~70 Mo). Fallback moteur
   unique + swap `modelPath` documenté si thrash disque pénalisant. Le 4B reste
   une piste « haute qualité » optionnelle pour machines avec plus de RAM.

2. **Périmètre langues V1.** ✅ **RÉSOLU par le gate (§1bis)** : EN/ES/DE/IT en
   V1 (DE/IT sous garde-fou C), **JA hors V1**.

3. **Drag libre vs ancrages discrets.** *Reco :* livrer le drag libre
   (`performWindowDragWithEvent`, faisable) ; garder « 3-4 ancrages via menu chip »
   comme fallback si le focus pendant drag s'avère fragile sur Brave.

4. **Clé d'identité de conversation.** *Reco :* `bundleID + cleanedWindowTitle`
   en V1, en acceptant que « par conversation » dégénère en « par onglet/fenêtre »
   en web. Documenter la limite ; ne pas sur-investir.

5. **Activation du tap quand le HUD existe sans ghost FR.** *Reco :* élargir
   `setActive(true)` à « HUD affiché » (Phase 5). Documenter que ⌘↩ commit
   consomme la touche → un 2e ⌘↩ (tap éteint) envoie via Intercom. C'est cohérent
   avec « commit ≠ envoi ».

6. **Mécanisme B dès V1 ou différé ?** *Reco :* livrer le HUD + commit + C
   d'abord (Phases 1-5), B en Phase 6 après prototype bench (la plage de logprobs
   utile au seuil de surlignage est à mesurer). B est un enrichissement, pas un
   bloquant.

7. **Style de traduction (injection prose) en V1 ?** *Reco :* différer.
   Style-only via `rank(.prose)` est faisable sans migration DB, mais le findings
   handoff montre que le recall ne généralise pas → le sens vient du modèle. Garder
   pour un milestone ultérieur (corpus de PAIRES FR→cible nécessite une migration
   DB : nouvelle colonne via `addSourceColumnIfNeeded` + `EntrySource .translation`).
