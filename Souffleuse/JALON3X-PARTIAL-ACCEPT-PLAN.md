# Plan : acceptation partielle (word-by-word) à la Cotypist

Document auto-contenu pour exécution par une session Claude fraîche
(post-`/clear`). Tout le contexte nécessaire est ci-dessous — pas
besoin de la conversation antérieure.

## Pourquoi

Aujourd'hui (commit `e8fb5c0`), Souffleuse n'a qu'un mode binaire
d'acceptation : Tab insère TOUTE la suggestion d'un coup. Cotypist
propose mieux — Tab insère **un mot à la fois**, le reste de la
suggestion reste en ghost gris. L'utilisateur peut taper sa propre
suite quand la suggestion diverge, ou re-Tab pour accepter le mot
suivant. C'est "surprisingly effective in practice" (citation
Cotypist) — la prédiction n'a pas besoin d'être parfaite sur 10 mots,
juste sur le suivant.

Référence : voir la capture Cotypist montrant 3 réglages :
- **Complete only the next word** → Tab
- **Include trailing space** → toggle (ajouter un espace après le mot
  accepté pour enchaîner)
- **Trigger full completion** → raccourci alternatif (Shift+@ chez
  Cotypist) pour tout accepter d'un coup

## État actuel du code à connaître

### Acceptation actuelle (Tab)

Fichier : `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`

Méthode `handleKey(_ key: KeyInterceptor.Key)` ligne ~678. Quand
`key == .tab` et qu'une suggestion LLM est en attente :

1. Lit `predictor.suggestion` (string entière)
2. `axClient.inject(suggestion)` — injecte TOUT
3. Enregistre éventuellement dans `TypingHistoryStore` (perso)
4. `predictor.cancel()` + `overlay.hide()` + `lastPredictedPrefix = nil`

C'est cette branche `pending.typo == nil` qu'on va modifier pour le
mode partiel. La branche typo (au-dessus, ligne ~688) reste inchangée
— une correction de typo s'accepte toujours en entier.

### KeyInterceptor

Fichier : `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift`
(à vérifier avec `ls Sources/SouffleuseInput/`). Expose un enum
`Key { case tab, esc, … }`. On peut potentiellement étendre l'enum
pour ajouter `.shiftTab` ou `.backtick` si on veut un raccourci
"accept all" séparé.

### Préférences

Fichier : `Souffleuse/Sources/Souffleuse/PreferencesStore.swift`
(@Observable @MainActor). Pattern :

```swift
private enum K {
    static let partialAcceptEnabled = "partialAcceptEnabled"
    static let trailingSpaceOnPartial = "trailingSpaceOnPartial"
}

var partialAcceptEnabled: Bool {
    didSet { UserDefaults.standard.set(partialAcceptEnabled, forKey: K.partialAcceptEnabled) }
}
// idem trailingSpaceOnPartial

// init
self.partialAcceptEnabled = (d.object(forKey: K.partialAcceptEnabled) as? Bool) ?? true
self.trailingSpaceOnPartial = (d.object(forKey: K.trailingSpaceOnPartial) as? Bool) ?? true
```

### Préférences UI

Fichier : `Souffleuse/Sources/Souffleuse/PreferencesWindow.swift`.
Y ajouter une section "Acceptation" avec deux toggles et une
description courte (mimer le style Cotypist : phrase d'explication
sous chaque switch).

### Predictor

Fichier : `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`.
La propriété `suggestion: String` est `@Observable` — quand on la
mute depuis AppDelegate (pour ne garder que le reste), l'overlay
re-render au prochain tick.

⚠️ Piège : le predictor lance des `Task` qui peuvent overwriter
`suggestion` quand le streaming MLX produit de nouveaux chunks. Donc
si on mute manuellement `suggestion` SANS canceler le predictor, le
chunk suivant écrasera notre version "tronquée". Solution : appeler
`predictor.cancel()` AVANT de set la valeur tronquée.

Mais on veut aussi BLOQUER une nouvelle prédiction tant qu'il y a du
ghost restant (sinon le prochain tick va voir `prefix != lastPredictedPrefix`
parce que le prefix a changé après inject, et déclencher une nouvelle
prédiction). D'où le besoin d'un flag.

## Architecture cible

### Nouveaux états AppDelegate

```swift
/// La suggestion "restante" après acceptations partielles. Tant qu'elle
/// est non-vide, l'overlay l'affiche à la place de predictor.suggestion,
/// et tick() ne déclenche pas de nouvelle prédiction.
@MainActor private var partialRemainder: String = ""
```

### Nouvelle préférence

Dans `PreferencesStore` :

- `partialAcceptEnabled: Bool` (default `true`)
- `trailingSpaceOnPartial: Bool` (default `true`)

### Flow de tick() (modifications)

Aux endroits où on consulte `predictor.suggestion` (lignes ~668 et
~656 actuellement), prioriser `partialRemainder` :

```swift
let suggestion = !partialRemainder.isEmpty
    ? partialRemainder
    : predictor.suggestion
```

Avant `predictor.predict(...)` (ligne ~656), bail si on est en mode
remainder actif :

```swift
if !partialRemainder.isEmpty {
    // Don't ask the model for a new completion — we still have
    // unconsumed text from the previous suggestion. The remainder
    // is reset when the user dismisses (Esc), types something
    // that diverges, or accepts the last chunk.
} else if prefix != lastPredictedPrefix {
    lastPredictedPrefix = prefix
    predictor.predict(...)
}
```

### Flow de handleKey(.tab)

```
si typo non-nil → branche existante inchangée
sinon si suggestion (=remainder ou predictor.suggestion) non-vide :
    si partialAcceptEnabled :
        chunk = nextChunk(suggestion, trailingSpace: trailingSpaceOnPartial)
        rest = suggestion[chunk.count:]
        axClient.inject(chunk)
        si rest.isEmpty :
            // Dernier chunk accepté — comportement de fin = identique à full accept
            partialRemainder = ""
            predictor.cancel()
            lastPredictedPrefix = nil
            overlay.hide()
            interceptor.setActive(false)
            // Enregistrer la TypingHistoryEntry avec la suggestion COMPLÈTE
            // (accumulée depuis le premier Tab partiel) — voir section persistance
        sinon :
            partialRemainder = rest
            predictor.cancel()  // stoppe le streaming pour qu'il n'écrase pas
            // NE PAS cacher l'overlay — tick() va le re-rendre avec partialRemainder
            // NE PAS reset lastPredictedPrefix — sinon tick re-fire une prédiction
    sinon (mode actuel "full accept") :
        // Comportement actuel inchangé
        ...
```

### handleKey(.esc) modification

Si `partialRemainder` non-vide, le clear comme une dismissal normale :

```swift
case .esc:
    if !partialRemainder.isEmpty {
        partialRemainder = ""
        overlay.hide()
        interceptor.setActive(false)
        // Marquer dismissed pour ne pas re-suggérer immédiatement
        // (existant : dismissedForText = snap.text)
        return true
    }
    // ... branche typo existante
```

### Détection de chunk (nouvelle fonction pure)

Nouveau fichier : `Souffleuse/Sources/SouffleuseInput/ChunkSplitter.swift`
(ou dans `SouffleuseTyping` si plus logique côté domaine — c'est de
la manipulation de string pure, pas de plumbing IO).

```swift
public enum ChunkSplitter {
    /// Returns the prefix of `s` corresponding to the next "chunk":
    /// one word (alphanumeric / apostrophe / hyphen) plus any trailing
    /// punctuation (.,;:!?) and optionally one trailing space.
    ///
    /// Examples (with trailingSpace=true) :
    ///   "Je m'appelle Gabriel, "  →  "Je "
    ///   "m'appelle Gabriel, "     →  "m'appelle "
    ///   "Gabriel, "               →  "Gabriel, "
    ///   "."                       →  "."
    ///
    /// With trailingSpace=false, the trailing single space is omitted:
    ///   "Je m'appelle Gabriel, "  →  "Je"
    public static func nextChunk(_ s: String, trailingSpace: Bool) -> String {
        // Skip leading whitespace
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        // Consume word chars (letters, digits, apostrophe, hyphen)
        while i < s.endIndex, isWordChar(s[i]) { i = s.index(after: i) }
        // Consume trailing punctuation
        while i < s.endIndex, isTrailingPunct(s[i]) { i = s.index(after: i) }
        // Optionally include one trailing whitespace
        if trailingSpace, i < s.endIndex, s[i].isWhitespace {
            i = s.index(after: i)
        }
        return String(s[s.startIndex..<i])
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }

    private static func isTrailingPunct(_ c: Character) -> Bool {
        ".,;:!?…)]}»".contains(c)
    }
}
```

### Persistance (TypingHistoryStore)

Le code actuel n'enregistre une entrée que sur l'acceptation complète
(`accepted: suggestion` ligne ~722). Avec le mode partiel, l'utilisateur
peut accepter mot-par-mot et taper sa propre suite à un moment. Deux
options :

**A. Accumulateur** : garder la suggestion ORIGINALE (avant le 1er
partial accept) dans un autre champ, et n'enregistrer l'entrée que
quand soit (a) le dernier chunk est accepté, soit (b) une déviation
intervient. Plus précis pour l'apprentissage personnel mais plus
complexe.

**B. Au fil de l'eau** : enregistrer chaque chunk individuellement.
Plus simple mais bruite l'historique avec des entrées de 1-2 mots.

Recommandation : **A** (accumulateur). Champ supplémentaire :

```swift
@MainActor private var partialAcceptedSoFar: String = ""
@MainActor private var partialAcceptedAtPrefix: String = ""
```

À chaque Tab partiel : `partialAcceptedSoFar += chunk`. Au moment du
dernier chunk OU d'une dismissal manuelle (Esc, ou divergence détectée),
on enregistre `TypingHistoryEntry(accepted: partialAcceptedSoFar, contextBefore: partialAcceptedAtPrefix, …)`
puis reset.

Si l'utilisateur dévie (tape un caractère hors-chunk), le tick()
courant va détecter `prefix != lastPredictedPrefix + chunks_accepted_so_far`
et reset le mode partiel — voir section "détection de divergence" ci-dessous.

### Détection de divergence

Quand l'utilisateur a accepté quelques chunks puis tape sa propre
suite, on doit reset le mode partiel et re-déclencher une prédiction.

Dans `tick()`, après avoir calculé `prefix` :

```swift
if !partialRemainder.isEmpty {
    // Vérifier que le texte actuel du champ matche bien ce qu'on
    // attendait après les chunks acceptés. Si non, l'user a divergé.
    let expectedTail = partialAcceptedSoFar
    if !prefix.hasSuffix(expectedTail) {
        // Divergence — reset, accepter ce qui a été pris jusqu'ici
        if !partialAcceptedSoFar.isEmpty {
            // Enregistrer dans l'history puis reset
            recordPartialAcceptanceToHistory()
        }
        partialRemainder = ""
        partialAcceptedSoFar = ""
        partialAcceptedAtPrefix = ""
        // tick() continue normalement → re-prédiction
    }
}
```

### (Optionnel phase 2) Raccourci "accept all"

Si on veut un second raccourci pour "tout accepter d'un coup" (comme
Cotypist Shift+@), il faut étendre `KeyInterceptor.Key` (probablement
ajouter `.acceptAll` reconnu via Shift+keycode). Hors scope phase 1
sauf si trivial à câbler. Phase 1 : Tab = accept partial, Esc = dismiss.

## Plan d'exécution (ordre suggéré)

1. **ChunkSplitter** + tests unitaires (10-15 cas : début, fin, ponctuation FR, apostrophes, mid-suggestion, leading whitespace, suggestion vide, trailingSpace on/off)
2. **PreferencesStore** : ajouter `partialAcceptEnabled` + `trailingSpaceOnPartial`
3. **PreferencesWindow** : section UI "Acceptation" avec les 2 toggles
4. **AppDelegate states** : `partialRemainder`, `partialAcceptedSoFar`, `partialAcceptedAtPrefix`
5. **AppDelegate tick()** :
   - prioriser `partialRemainder` quand non-vide pour l'overlay
   - bail avant `predictor.predict()` si remainder actif
   - détection de divergence
6. **AppDelegate handleKey(.tab)** : branche partielle (extract chunk via ChunkSplitter, inject, set remainder, cancel predictor sans clear lastPredictedPrefix)
7. **AppDelegate handleKey(.esc)** : reset remainder si non-vide
8. **TypingHistoryStore wiring** : enregistrement accumulé à la fin (dernier chunk OU divergence OU dismissal)
9. **Tests AppDelegate** : difficile à tester directement (MainActor + AppKit) — privilégier les tests sur ChunkSplitter et exposer assez de logique en helpers statiques testables (genre `static func nextRemainderAfter(chunk:in:)`)
10. **Build, swift test, make-app.sh, smoke test live dans TextEdit + Notes + Brave**

## Acceptance criteria

- ✅ `swift build` clean (Swift 6)
- ✅ `swift test` : tous les tests existants (55) + nouveaux (≥10 sur ChunkSplitter) verts
- ✅ Avec `partialAcceptEnabled = true` (default) :
  - Tab sur "Je m'appelle Gabriel" insère "Je " (avec trailing space) et garde "m'appelle Gabriel" en ghost
  - Re-Tab → "m'appelle " inséré, "Gabriel" en ghost
  - Re-Tab → "Gabriel" inséré, plus de ghost
  - Esc à n'importe quel moment efface le remainder, masque le ghost
  - Si l'user tape sa propre lettre au milieu → remainder cleared, nouvelle prédiction
- ✅ Avec `partialAcceptEnabled = false` :
  - Comportement strictement identique à avant (Tab = accept all)
- ✅ Personalization history :
  - L'entrée enregistrée contient la suggestion ACCEPTÉE EN TOTALITÉ
    (cumul des chunks), pas chaque chunk individuel
  - Si l'user dévie après 2 chunks, on enregistre uniquement ces 2
    chunks (pas la suggestion entière qui n'a pas été utilisée)
- ✅ Pas de race avec le streaming MLX (le predictor est canceled
  avant d'overwriter `suggestion`)
- ✅ Pas de double-Tab bug régression (déjà couvert par `dismissedForText`)

## Hors scope phase 1

- Raccourci "trigger full completion" alternatif (Shift+@ chez
  Cotypist). Si urgent on l'ajoute en phase 2.
- Settings UI pour rebinder Tab → autre touche
- Mode "accept N words at once" (Cotypist a juste 1-word, on copie)
- Detection avancée de divergence (genre comparer mot à mot, pas
  juste hasSuffix)

## Pointers vers les fichiers existants

- `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`
  - `handleKey(_ key:)` ligne ~678
  - Branche typo (sur Tab) ligne ~688 — ne pas casser
  - Branche LLM (sur Tab) ligne ~705-750 — c'est elle qu'on refactore
  - Section enregistrement personalization ligne ~712-731 — à
    déplacer / adapter pour le mode accumulé
- `Souffleuse/Sources/Souffleuse/PreferencesStore.swift`
  - Pattern `K.xxx` + didSet + init défaut, ligne ~80-150
- `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift`
  - `suggestion: String` — @Observable propriété mutable
  - `cancel()` — annule la Task de streaming en cours
- `Souffleuse/Sources/Souffleuse/PreferencesWindow.swift`
  - Style des sections existantes : Form / Section / Toggle
- `Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift`
  - Style Swift Testing (`@Test`, `#expect`), pas XCTest

## Avant de coder

- Lire les 4 fichiers ci-dessus jusqu'au bout pour comprendre les
  conventions et pas casser des invariants subtils (`dismissedForText`,
  `lastPredictedPrefix`, `interceptor.setActive`, gestion des actors
  MainActor vs threads CGEventTap).
- Lire le commit message `git log -1 e8fb5c0` pour voir comment on
  documente les couches empilées.
- Confirmer avec `swift test` que le baseline est vert avant
  d'attaquer (55/55 doivent passer).

## Quand c'est fini

```bash
cd Souffleuse
swift test                # toutes vertes
bash make-app.sh          # bundle .app produit
# Kill l'ancienne instance Souffleuse + relance la nouvelle
# (l'utilisateur fera ça manuellement après ré-autorisation AX)
git add -A
git commit -m "Acceptation partielle word-by-word..."  # voir commit e8fb5c0 pour le style
```
