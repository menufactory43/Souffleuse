# Jalon 2.5 — ContextEnricher

> Augmenter la qualité des suggestions en injectant du contexte non-textuel : nom de l'app, titre de fenêtre, presse-papier, capture visuelle OCR. Tout opt-in, tout local, rien persisté. Mesurer l'impact réel A/B avant de déclarer la victoire.

## Pré-requis (état au démarrage)

- `git log` : J2.D committé jusqu'à `f055aa7` (onboarding + ⌃⌥⌘S toggle)
- `Souffleuse.app` se lance, ghost text apparaît dans TextEdit/Notes/Mail/Safari
- Aucune permission Screen Recording demandée à ce stade

Lire avant de commencer :
- `ARCHITECTURE.md` §3.2 ContextEnricher, §5/5.bis privacy
- `JALON2-PLAN.md` ligne 274 (note sur Screen Recording opt-in, Electron fallback)

## Définition of done

L'utilisateur active "Enrichissement contextuel" depuis la menubar. Au prochain focus change vers Mail, Souffleuse :
1. lit le bundle ID + titre fenêtre (toujours)
2. lit le presse-papier (sauf si app blocklistée)
3. capture la fenêtre frontale, OCR via Vision, garde top 500 chars

Ces 3 signaux sont préfixés au prompt envoyé au modèle. Le harness A/B montre **un delta mesurable** d'acceptation (>5pp) sur 30 min d'usage réel, sinon on jette une source.

Toggle global ⌃⌥⌘E désactive instantanément tout enrichissement. Screenshots jamais sur disque. Clipboard non lu si app frontale ∈ blocklist.

## Risques connus et contre-mesures

| # | Risque | Contre-mesure |
|---|---|---|
| R1 | OCR Vision lent (>200 ms) sur grosse fenêtre 4K | Downscale capture à 1280px max avant OCR, mesurer avec `BENCHMARKS.md` |
| R2 | ScreenCaptureKit demande la permission au premier appel et bloque le thread | Pré-check `CGPreflightScreenCaptureAccess()` + onboarding séparé |
| R3 | Clipboard contient un mot de passe copié | Blocklist d'apps + détection heuristique (entropie haute, ≤32 chars sans espace) |
| R4 | Capture inclut nos propres overlays / panneaux Souffleuse | Filtrer notre PID via `SCContentFilter(.excludingApplications:[souffleusePid])` |
| R5 | Préfixe explose le contexte modèle, dégrade qualité | Cap dur 500 chars par source, mesurer impact via harness A/B |
| R6 | Cache stale : utilisateur scroll dans la fenêtre, OCR obsolète | Invalider cache sur `kAXSelectedTextChanged` aussi, pas que sur focus app |
| R7 | Privacy : un screenshot finit accidentellement dans un log | `assert(false)` dans tout chemin qui sérialise une `CGImage` en debug builds |
| R8 | App Sandbox / hardened runtime entitlement manquant pour ScreenCaptureKit | Ajouter `com.apple.security.device.audio-input`/screen-capture entitlements, vérifier au build |

## Découpage en 4 phases

Séquentiel A → B → C → D. Chaque phase a un livrable testable et un commit.

---

### Phase 2.5.A — Socle léger : ClipboardReader + AppContextProbe (1 jour)

**But** : isoler les 2 sources qui ne demandent aucune permission supplémentaire, valider leur intégration avant de toucher ScreenCaptureKit.

**Livrable**
- `Sources/SouffleuseContext/ClipboardReader.swift` — actor, lecture `NSPasteboard.general.string(forType: .string)`, troncature 500 chars, blocklist par bundle ID frontale
- `Sources/SouffleuseContext/AppContextProbe.swift` — actor qui interroge AX pour `kAXTitleAttribute` de la fenêtre focalisée + bundle ID via `NSWorkspace.shared.frontmostApplication`
- Démo CLI `Sources/SouffleuseContextProbe/main.swift` qui imprime toutes les 500 ms :
  ```
  [App: com.apple.mail | Window: "Re: Invoice Q2"]
  [Clipboard: "https://example.com/invoice…"]
  ```

**Edge cases à valider**
- Pas de fenêtre focalisée → output `[App: -]`
- Clipboard vide → ligne absente, pas `[Clipboard: ]`
- Frontmost = 1Password → ligne Clipboard absente (blocklist)
- Clipboard image (pas string) → ignoré silencieusement
- Bundle ID non disponible (process exotique) → fallback sur localizedName

**Test acceptance**
```bash
swift build --target SouffleuseContextProbe
.build/debug/SouffleuseContextProbe
# focus successivement Mail, Notes, Safari, 1Password recherche
# vérifier blocklist sur 1Password, vérifier titre fenêtre toujours présent
```

**Commit attendu** : `Jalon 2.5.A: ClipboardReader + AppContextProbe + CLI demo`

---

### Phase 2.5.B — ScreenCapturer + OCR Vision (2 jours)

**But** : capture on-demand de la fenêtre frontale et extraction texte via Vision, avec budget temps strict.

**Livrable**
- `Sources/SouffleuseContext/ScreenCapturer.swift` — actor, `SCStreamConfiguration` one-shot via `SCScreenshotManager.captureImage(contentFilter:configuration:)` (macOS 14+)
- `Sources/SouffleuseContext/VisionOCR.swift` — `VNRecognizeTextRequest` `.fast`, langues `[fr, en]`, top 500 chars concaténés ligne à ligne
- Étendre `SouffleuseContextProbe` avec flag `--capture` qui ajoute la ligne `[Visible: …]`

**Spec ScreenCaptureKit**
```swift
let content = try await SCShareableContent.current
guard let frontWindow = content.windows
    .filter({ $0.owningApplication?.bundleIdentifier == frontBundleID })
    .filter({ $0.isOnScreen })
    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
else { return nil }

let filter = SCContentFilter(desktopIndependentWindow: frontWindow)
let config = SCStreamConfiguration()
config.width = min(Int(frontWindow.frame.width), 1280)
config.height = Int(Double(config.width) * frontWindow.frame.height / frontWindow.frame.width)
config.showsCursor = false
config.capturesAudio = false

let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
```

**Spec OCR**
```swift
let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast       // pas .accurate, on veut <100 ms
request.recognitionLanguages = ["fr-FR", "en-US"]
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: image)
try handler.perform([request])
let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
return lines.joined(separator: " ").prefix(500)
```

**Permission flow**
- Pré-check : `CGPreflightScreenCaptureAccess()` avant tout appel
- Si refusé : enricher tourne sans `[Visible:]`, jamais de prompt automatique
- Onboarding J2.5 ajoute un écran "Améliorer le contexte" avec bouton qui ouvre `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`

**Privacy garde-fous (code-level)**
- `CGImage` jamais sérialisée ; assert dans `OSLog.debug` qu'on ne logge que la longueur
- Capture exclut le PID Souffleuse via `SCContentFilter(.excludingApplications: ...)` quand l'API le permet (sinon filtre la fenêtre par titre)
- Pas de retention : `image` libéré dès OCR fini

**Budget perf à mesurer** (BENCHMARKS.md addendum)
- Capture : <50 ms p95
- OCR `.fast` 1280px : <100 ms p95
- Total round-trip enrichissement : <200 ms, sinon on dégrade (skip `[Visible:]`)

**Test acceptance**
```bash
swift build --target SouffleuseContextProbe
.build/debug/SouffleuseContextProbe --capture
# focus Safari sur un article → vérifier [Visible: titre + premiers paragraphes]
# focus Mail → vérifier sujet + corps visible
# refus permission Screen Recording → vérifier que [Visible:] disparaît proprement
# top -pid souffleusectx → vérifier RAM stable, pas de leak après 100 captures
```

**Commit attendu** : `Jalon 2.5.B: ScreenCapturer + Vision OCR + perf budget`

---

### Phase 2.5.C — ContextEnricher orchestrateur (1 jour)

**But** : un seul point d'entrée qui assemble les 3 sources, gère cache et invalidation, et formate le préfixe selon ARCHITECTURE.md.

**Livrable**
- `Sources/SouffleuseContext/ContextEnricher.swift` — actor central
- Intégration dans le pipeline `Souffleuse` : le prompt envoyé à MLX est désormais `enriched + userText` au lieu de `userText` seul

**API**
```swift
actor ContextEnricher {
    struct Enriched {
        let app: String?
        let windowTitle: String?
        let clipboard: String?
        let visible: String?
        var prefix: String { /* format ARCHITECTURE.md §3.2 */ }
    }

    func snapshot(for bundleID: String) async -> Enriched
    func invalidate()  // appelé sur focus change ET kAXSelectedTextChanged
}
```

**Format prefix** (strict — pas d'écart) :
```
[App: Mail | Window: "Re: Invoice Q2"]
[Clipboard excerpt: …]
[Visible context: …]
[User text]: <prompt utilisateur>
```
- Lignes manquantes (clipboard vide, capture refusée) → ligne entière omise
- Pas de retour ligne en trop, pas de séparateur `---`

**Cache** : par bundle ID, TTL 5s, invalidé hors-TTL sur focus change

**Trigger** : `FocusObserver` appelle `enricher.snapshot()` **uniquement au focus change app**, jamais par frappe. Le résultat est gardé jusqu'au prochain focus change ou TTL expiré.

**Wiring dans Predictor**
- Predictor reçoit `Enriched` (optionnel) en plus du `userText`
- Si `enriched == nil` ou enrichissement désactivé → fallback comportement actuel (prompt = userText)
- Pas de chat template, on prepend le préfixe brut

**Test acceptance**
- Lancer Souffleuse normal, focus Mail, taper "Bonjour" → log debug montre le préfixe complet envoyé à MLX
- Toggle off enrichissement → log montre prompt sans préfixe
- Focus 1Password → log montre `[App:…]` mais pas `[Clipboard:…]`

**Commit attendu** : `Jalon 2.5.C: ContextEnricher orchestrateur + intégration Predictor`

---

### Phase 2.5.D — UI menubar + privacy + harness A/B (1-2 jours)

**But** : exposer le toggle, mesurer si l'enrichissement aide vraiment, garde-fous privacy visibles.

**Livrable**
- Menubar `NSStatusItem` : nouveau toggle "Enrichissement contextuel ✓"
- Sous-toggle : "Inclure capture d'écran" (séparé, demande Screen Recording la première fois)
- Raccourci ⌃⌥⌘E pour désactiver instantanément tout enrichissement (audible via brève notification)
- `BlocklistConfig.swift` : liste codée en dur (`com.1password.*`, `com.apple.keychainaccess`, `com.bnpparibas.*`, `com.lcl.*`, `com.boursorama.*`, etc.) + chargement utilisateur via fichier `~/Library/Application Support/Souffleuse/clipboard-blocklist.txt`
- `Sources/SouffleuseBench/EnrichmentABBench.swift` : extension du bench existant qui fait tourner 20 prompts captures de séances réelles, génère **deux** suggestions par prompt (avec/sans préfixe) et logge un JSONL avec champs `{prompt, accepted_without, accepted_with, latency_without_ms, latency_with_ms, prefix_chars}`

**Critères d'acceptation A/B** (à atteindre AVANT de déclarer J2.5 terminé)
- Sur 30 min d'usage réel (compose mail + notes + recherche web) :
  - Acceptation Tab **+5pp minimum** avec enrichissement vs sans
  - Latence p95 enrichissement-actif **< 250 ms** au-delà de la latence base
  - 0 fuite : grep dans `~/Library/Logs/` du nom d'un mot collé en clipboard pendant le test → 0 résultat
- Si delta acceptation <5pp : décider source par source laquelle on coupe (probablement OCR si trop bruité)

**Onboarding flow Screen Recording**
- Lors de l'activation du sous-toggle "Inclure capture d'écran" :
  1. `CGRequestScreenCaptureAccess()` (déclenche le prompt système)
  2. Si refus : revert le toggle, afficher mini-alert "Permission requise"
  3. Si accord : test capture immédiat sur la fenêtre actuelle, montre overlay "OCR test : [3 premiers mots détectés]"

**Privacy UI visible**
- Menubar montre un indicateur point bleu quand une capture est en cours (<200 ms)
- Préférence "Voir le dernier prompt envoyé au modèle" (debug, fenêtre simple) pour que l'utilisateur audite ce qui sort

**Test acceptance final Jalon 2.5**
1. Toggle "Enrichissement contextuel" off → comportement identique J2 strict
2. Toggle on (sans Screen Recording) → préfixe contient `[App:]` + `[Clipboard:]` quand pertinent
3. Toggle "Inclure capture d'écran" on → prompt système, accord, point bleu apparaît à chaque focus change
4. Focus 1Password → AUCUN clipboard ne fuite dans le prompt
5. ⌃⌥⌘E → tous les enrichissements coupés instantanément, ghost text fonctionne toujours (prompt nu)
6. Bench A/B exporté en JSONL, **delta acceptation >5pp documenté** dans `BENCHMARKS.md`
7. `grep -r "<un mot test unique copié>" ~/Library/Logs/` → 0 résultat

**Commit attendu** : `Jalon 2.5.D: toggle menubar + blocklist + harness A/B + bench results`

---

## Hors scope Jalon 2.5 (reportés Jalon 3)

- Préférences UI complète (allowlist par app, choix langues OCR, taille cap configurable)
- Persistance per-app du choix enrichissement on/off
- Refactor XPC 3-process (UI / AXAgent / InferenceAgent)
- Selection courante (`kAXSelectedTextAttribute` lecture comme source distincte) — déjà disponible via FocusObserver, à intégrer si delta A/B le justifie
- KV cache cross-frappe avec préfixe stable
- Détection heuristique mot-de-passe dans clipboard (au-delà de la blocklist d'apps)

## Estimation totale

5-6 jours dev solo. Phase la plus risquée : 2.5.B (ScreenCaptureKit + budget perf). Phase la plus stratégique : 2.5.D (le bench A/B décide si J2.5 livre une valeur réelle ou si on dégage des sources).

## Critères pour passer Jalon 2.5 → Jalon 3

Tous les tests d'acceptance Phase D passent **et** le bench A/B sur 30 min d'usage réel montre **+5pp d'acceptation minimum avec enrichissement actif**. Si le delta est sous le seuil, on coupe les sources qui n'apportent rien (probablement OCR avant clipboard) et on documente la décision dans `ARCHITECTURE.md` §10 avant de passer à J3.

## Prochain commit attendu après ce plan

```
git checkout -b jalon-2.5
# coder Phase 2.5.A
git add Sources/SouffleuseContext Sources/SouffleuseContextProbe Package.swift
git commit -m "Jalon 2.5.A: ClipboardReader + AppContextProbe + CLI demo"
```
