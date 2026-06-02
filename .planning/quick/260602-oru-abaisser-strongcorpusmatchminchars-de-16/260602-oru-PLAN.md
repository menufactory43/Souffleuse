---
phase: quick-260602-oru
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - Souffleuse/Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift
  - Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift
  - Souffleuse/Tests/SouffleuseTests/CorpusFastPathTests.swift
autonomous: true
requirements: [QUICK-260602-oru]

must_haves:
  truths:
    - "Le seuil strong-corpus after-space passe de 16 à 12 caractères verbatim."
    - "Le call-site after-space utilise un seuil runtime-overridable via MW_STRONG_MINCHARS."
    - "Le call-site mid-word reste figé sur midWordCorpusMatchMinChars (8) — inchangé."
    - "Un strongCorpusMatch avec ~12-15 chars de contexte after-space retourne non-nil à minChars=12 mais nil à minChars=16."
    - "Les ~640 @Test existants restent verts ; audit.sh passe."
  artifacts:
    - path: "Souffleuse/Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift"
      provides: "strongCorpusMatchMinChars=12 + strongCorpusMatchMinCharsRuntime (env MW_STRONG_MINCHARS)"
      contains: "strongCorpusMatchMinCharsRuntime"
    - path: "Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift"
      provides: "défaut du paramètre minChars de strongCorpusMatch = Tuning.strongCorpusMatchMinCharsRuntime"
      contains: "strongCorpusMatchMinCharsRuntime"
    - path: "Souffleuse/Tests/SouffleuseTests/CorpusFastPathTests.swift"
      provides: "@Test démontrant la bascule 12 vs 16 sur un contexte after-space ~12 chars"
      contains: "minChars: 12"
  key_links:
    - from: "SuggestionPolicy.swift:981 (after-space call-site)"
      to: "Tuning.strongCorpusMatchMinCharsRuntime"
      via: "valeur par défaut du paramètre minChars"
      pattern: "minChars: Int = Tuning.strongCorpusMatchMinCharsRuntime"
    - from: "strongCorpusMatchMinCharsRuntime"
      to: "ProcessInfo.processInfo.environment[\"MW_STRONG_MINCHARS\"]"
      via: "lecture env clampée >= 1"
      pattern: "MW_STRONG_MINCHARS"
---

<objective>
Réactiver le recall corpus (rappel historique) en début de phrase (after-space). La voie réelle pour ce cas est `SuggestionPolicy.strongCorpusMatch(...)`, dont le seuil after-space `strongCorpusMatchMinChars = 16` exige 16 caractères verbatim de contexte récent — trop pour des openers courts ("Bonjour, "). On abaisse à 12 et on rend le seuil env-overridable (`MW_STRONG_MINCHARS`) pour balayage A/B live.

Purpose: Le ghost doit rappeler les openers/salutations appris dès le début de phrase, comme Cotypist, sans dépendre d'un contexte de 16 chars.
Output: Seuil abaissé à 12 + variante runtime + couverture test démontrant la bascule, sans casser la suite ni audit.sh.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md

<interfaces>
<!-- Pattern de référence à suivre EXACTEMENT dans SuggestionPolicy+Tuning.swift -->

Variantes *Runtime existantes (le pattern à imiter), SuggestionPolicy+Tuning.swift:
```swift
// Float runtime
public static var afterSpaceL1BarRuntime: Float {
    if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_L1_BAR"],
       let f = Float(s) { return f }
    return afterSpaceL1Bar
}
// Int runtime clampé (le plus proche du besoin)
/// `MW_ESC_K` — nombre de branches.
public static var escBranchKRuntime: Int {
    if let s = ProcessInfo.processInfo.environment["MW_ESC_K"], let v = Int(s) { return max(0, v) }
    return escBranchK
}
```

Seuil after-space cible (SuggestionPolicy+Tuning.swift ~ligne 103):
```swift
public static let strongCorpusMatchMinChars: Int = 16   // → 12
```

Seuil mid-word à NE PAS toucher (~ligne 115):
```swift
public static let midWordCorpusMatchMinChars: Int = 8
```

Signature strongCorpusMatch (SuggestionPolicy.swift ~ligne 370-374):
```swift
public nonisolated static func strongCorpusMatch(
    userTail: String,
    snapshot: [TypingHistoryEntry],
    minChars: Int = Tuning.strongCorpusMatchMinChars   // → Tuning.strongCorpusMatchMinCharsRuntime
) -> (continuation: String, matchedChars: Int)?
```

Call-site after-space (SuggestionPolicy.swift ~ligne 981) — N'A PAS de minChars explicite (utilise le défaut) :
```swift
if let strong = SuggestionPolicy.strongCorpusMatch(
    userTail: userTail,
    snapshot: proseSnapshot
) {
```

Call-site mid-word (SuggestionPolicy.swift ~ligne 927) — explicite, NE PAS toucher :
```swift
if let strong = SuggestionPolicy.strongCorpusMatch(
    userTail: userTail,
    snapshot: proseSnapshot,
    minChars: SuggestionPolicy.Tuning.midWordCorpusMatchMinChars
) {
```

Helpers de test (CorpusFastPathTests.swift):
```swift
static func entry(_ context: String, _ accepted: String, source: EntrySource = .prose) -> TypingHistoryEntry {
    TypingHistoryEntry(timestamp: Date(), contextBefore: context, accepted: accepted, bundleID: nil, source: source)
}
```
Imports du fichier : `Testing`, `Foundation`, `SouffleusePersonalization`, `SouffleuseTyping`, `SouffleuseCore`, `@testable import Souffleuse`.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Abaisser le seuil à 12 + variante runtime MW_STRONG_MINCHARS</name>
  <files>Souffleuse/Sources/SouffleuseCore/SuggestionPolicy+Tuning.swift</files>
  <behavior>
    - `strongCorpusMatchMinChars` vaut 12 (était 16).
    - `strongCorpusMatchMinCharsRuntime` lit `MW_STRONG_MINCHARS` (Int) si présent et parsable, clampé `max(1, v)` ; sinon retombe sur `strongCorpusMatchMinChars` (12).
    - La variante reste pure/`nonisolated` (var calculée static, aucun état), comme `escBranchKRuntime`.
  </behavior>
  <action>
Dans `SuggestionPolicy+Tuning.swift`, vers ligne 103 :
1. Changer `public static let strongCorpusMatchMinChars: Int = 16` → `= 12`. Mettre à jour le commentaire `///` au-dessus (~ligne 101 : "~16 chars ≈ several words") pour citer 12 et le pourquoi (réactiver le recall des openers courts après-espace, "Bonjour, " = ~9 chars, 12 reste assez long pour signaler un contexte connu ré-entré). Ne PAS inventer d'autre justification que l'objectif du plan.
2. AJOUTER juste après la constante une variante runtime, suivant EXACTEMENT le pattern de `escBranchKRuntime` (Int clampé). Doc `///` citant la variable d'env `MW_STRONG_MINCHARS` et son usage (A/B live du seuil after-space sans recompiler) :

```swift
/// `MW_STRONG_MINCHARS` — seuil after-space du strong-corpus, override live
/// (A/B sans rebuild, même pattern que `afterSpaceL1BarRuntime` /
/// `escBranchKRuntime`). Env absente ⇒ la constante (12). Clampé ≥ 1 pour
/// qu'une valeur dégénérée ne désactive pas la garde de longueur min.
public static var strongCorpusMatchMinCharsRuntime: Int {
    if let s = ProcessInfo.processInfo.environment["MW_STRONG_MINCHARS"], let v = Int(s) { return max(1, v) }
    return strongCorpusMatchMinChars
}
```

CONTRAINTE : ne PAS toucher `midWordCorpusMatchMinChars` (reste à 8). Pas de littéral inline ailleurs : le seuil vit dans Tuning.
  </action>
  <verify>
    <automated>cd Souffleuse && swift build 2>&1 | tail -20</automated>
  </verify>
  <done>Build OK ; `strongCorpusMatchMinChars == 12` ; `strongCorpusMatchMinCharsRuntime` présent, pur, lit MW_STRONG_MINCHARS clampé ≥ 1.</done>
</task>

<task type="auto">
  <name>Task 2: Brancher le call-site after-space sur le seuil runtime</name>
  <files>Souffleuse/Sources/SouffleuseCore/SuggestionPolicy.swift</files>
  <action>
Le call-site after-space (~ligne 981, commentaire "Phase 3 (b) — Cotypist short fast-path") N'A PAS d'argument `minChars:` → il utilise le défaut du paramètre. Pour qu'il prenne le seuil runtime, changer la valeur par défaut du paramètre dans la signature de `strongCorpusMatch` (~ligne 370-373) :

`minChars: Int = Tuning.strongCorpusMatchMinChars` → `minChars: Int = Tuning.strongCorpusMatchMinCharsRuntime`

C'est la voie la plus propre : un seul point de changement, le call-site after-space hérite du runtime, et le call-site mid-word (~ligne 927) reste intact car il passe `minChars: SuggestionPolicy.Tuning.midWordCorpusMatchMinChars` explicitement.

CONTRAINTE : NE PAS modifier le call-site mid-word (~ligne 927) ni `midWordCorpusMatchMinChars`. Vérifier après coup qu'il reste explicite à 8.

VIGILANCE (point pour l'exécuteur) : le passage 16→12 peut faire muter le comportement de tests existants qui appellent `strongCorpusMatch` SANS `minChars` explicite et qui assument le défaut=16. Inventaire fait au plan : les tests existants de `CorpusFastPathTests.swift` utilisent soit des overlaps longs (≥16 chars, ex. "Cordialement, Gabriel " = 22 chars → toujours non-nil), soit des fragments courts (≤8 chars, ex. "Bonj" → toujours nil) — tous robustes à 12 comme à 16. Si malgré tout un test casse, ajuster LE TEST (sa valeur attendue ou son `minChars` explicite), JAMAIS la logique de production.
  </action>
  <verify>
    <automated>cd Souffleuse && swift build 2>&1 | tail -20</automated>
  </verify>
  <done>Build OK ; signature `strongCorpusMatch` a `minChars: Int = Tuning.strongCorpusMatchMinCharsRuntime` ; call-site mid-word ~927 toujours `minChars: ...midWordCorpusMatchMinChars`.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Test de bascule 12-vs-16 + run suite + audit</name>
  <files>Souffleuse/Tests/SouffleuseTests/CorpusFastPathTests.swift</files>
  <behavior>
    - Avec un userTail after-space dont le suffixe verbatim présent dans une entrée `.prose` fait ~12-15 chars : `strongCorpusMatch(..., minChars: 12)` retourne NON-nil ; `strongCorpusMatch(..., minChars: 16)` retourne nil.
    - Le test ne dépend pas de l'env (appelle les deux valeurs explicitement), il démontre la bascule.
  </behavior>
  <action>
Ajouter un `@Test` dans `CorpusFastPathTests.swift`, à côté des tests "strongCorpusMatch pure helper" (après `weakShortOverlapReturnsNil`, ~ligne 47), en réutilisant le helper `Self.entry(...)`.

Construire une fixture où le contexte after-space chevauchant verbatim fait entre 12 et 15 chars. Exemple :
- entry : `Self.entry("", "Bonjour, je vous remercie de votre message")`
- userTail : `"Bonjour, je "` (12 chars verbatim, finit par un espace → after-space).

Le suffixe commun "Bonjour, je " = 12 caractères. Donc :

```swift
@Test func afterSpaceOpenerMatchesAt12NotAt16() {
    let snap = [Self.entry("", "Bonjour, je vous remercie de votre message")]
    // Contexte after-space court (~12 chars) typique d'un opener : recall
    // attendu à 12, refusé à 16 (l'ancien seuil ratait les openers courts).
    let tail = "Bonjour, je "   // 12 chars verbatim
    #expect(SuggestionPolicy.strongCorpusMatch(userTail: tail, snapshot: snap, minChars: 12) != nil)
    #expect(SuggestionPolicy.strongCorpusMatch(userTail: tail, snapshot: snap, minChars: 16) == nil)
}
```

AVANT de finaliser le texte du test : vérifier le compte EXACT de caractères du suffixe commun avec la commande de verify (le helper `count` de Swift = Characters/graphèmes). Ajuster le `tail` pour qu'il tombe dans [12,15] verbatim si "Bonjour, je " ne fait pas exactement 12. Le matched-context du helper est le plus long suffixe de userTail qui est substring de l'entrée — s'assurer que ce suffixe ≥ 12 et < 16.

Puis lancer la suite complète et l'audit.
  </action>
  <verify>
    <automated>cd Souffleuse && swift test --filter CorpusFastPathTests 2>&1 | tail -25 && swift test 2>&1 | tail -15 && bash audit.sh 2>&1 | tail -15</automated>
  </verify>
  <done>Le nouveau @Test passe (non-nil à 12, nil à 16) ; la suite complète (~640 @Test) reste verte ; audit.sh passe (pas de print/NSLog/os_log user introduit).</done>
</task>

</tasks>

<verification>
- `swift build` OK après chaque task.
- `swift test` : nouveau test vert + aucun test existant cassé.
- `bash audit.sh` : invariants privacy intacts.
- Inspection : seul le call-site after-space hérite du seuil runtime ; mid-word figé à 8.
</verification>

<success_criteria>
- `strongCorpusMatchMinChars == 12`, `strongCorpusMatchMinCharsRuntime` lit `MW_STRONG_MINCHARS` (clampé ≥ 1).
- `strongCorpusMatch` défaut paramètre = `Tuning.strongCorpusMatchMinCharsRuntime`.
- Call-site mid-word (~927) inchangé (8).
- Test de bascule 12/16 vert ; suite complète verte ; audit.sh vert.
</success_criteria>

<output>
After completion, create `.planning/quick/260602-oru-abaisser-strongcorpusmatchminchars-de-16/260602-oru-SUMMARY.md`
</output>
