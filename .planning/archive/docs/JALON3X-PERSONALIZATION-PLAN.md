# Jalon 3.X — Personnalisation par historique de frappe

> Cible : matcher la qualité Cotypist sur du texte récurrent (mails, notes, messages) en biaisant les logits du modèle vers le vocabulaire/style de l'utilisateur. Sans entraîner — juste en pondérant les n-grammes au moment du sampling.
>
> Cette phase est insérée entre Jalon 3.C (typo + emoji + chat template + Qwen Instruct dispo) et Jalon 3.D (signature + DMG). Décidée 2026-05-22 après bench utilisateur montrant que Cotypist sur le même hardware/modèle bat largement Souffleuse — gap probable dans la perso, pas dans le modèle.

## Pré-requis (état au démarrage)

- Branche `jalon-3` HEAD au commit `4404638` (Gemma défaut, Qwen Instruct dispo dans le picker, chat template branch dans PredictorViewModel)
- Tous les tests de la branche jalon-3 passent (15/15)
- `audit.sh` passe (jamais de texte utilisateur dans `~/Library/Logs/Souffleuse.log`)
- `make-app.sh` produit un bundle fonctionnel
- Pas encore de fichier qui persiste du texte utilisateur sur disque (sauf Custom Instructions, saisies volontairement par l'utilisateur dans la fenêtre dédiée)

Lire avant de commencer :
- `ARCHITECTURE.md` §3.2 ContextEnricher (pour aligner format), §5.bis Threat model — **à étendre dans cette phase**
- `JALON3-PLAN.md` "Hors scope" — la perso était listée comme "post-v1", on l'avance ici
- `Sources/Souffleuse/PredictorViewModel.swift` — l'intégration du LogitProcessor s'y fait
- `.build/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/Evaluate.swift` lignes 189-220 — exemple de `LogitProcessor` (repetitionPenalty) qu'on reprend pour notre n-gram bias

## Définition of done

1. Toggle opt-in **"Apprendre de mes frappes"** (défaut OFF) dans Préférences > nouvel onglet **Personnalisation**.
2. Quand activé : chaque Tab acceptation enregistre `{contextBefore: dernière phrase de prefix, accepted: suggestion, bundleID: source}` dans un **fichier chiffré** `~/Library/Application Support/Souffleuse/history.aes` (AES-GCM, clé 256-bit en Keychain).
3. Ring buffer 200 entrées max, 50 KB max — rotation FIFO.
4. **Modèle n-gram** local (bigrammes + trigrammes) reconstruit en mémoire au chargement, mis à jour online à chaque ajout.
5. **NgramLogitBias** implémente `LogitProcessor`, branché dans `GenerateParameters.processor` quand le toggle est ON.
6. **Slider Personnalisation** Off → Max (0.0 → 2.0 sur logits) avec preview live.
7. **Per-app blocklist** : jamais d'enregistrement si bundleID ∈ blocklist (banques, password managers, terminaux — réutilise `ClipboardReader.mergedBlocklist()`).
8. Bouton **"Voir mes données collectées"** ouvre une fenêtre lisible avec les N dernières entrées en clair (audit user-side).
9. Bouton **"Tout supprimer"** zéroize le fichier + clé Keychain.
10. **Bench A/B** : harness mesure delta acceptation entre baseline (toggle OFF) et perso (toggle ON, slider max, 100+ entrées dans history) sur un corpus FR de 30+ prompts. Résultat documenté dans `BENCHMARKS.md`.
11. `audit.sh` étendu : interdit explicitement les chemins qui lisent `history.aes` vers stdout/stderr/log.
12. `ARCHITECTURE.md` §5.bis mis à jour : nouveau vector de threat (texte utilisateur persisté), countermesures documentées.

L'utilisateur active le toggle, écrit 20 mails de style normal pendant 2-3 jours, observe que ses suggestions utilisent ses tournures habituelles (formules de fin, noms de collègues, expressions récurrentes). Bench A/B sur ces 3 jours montre **delta acceptation ≥ 5pp** vs baseline.

## Risques connus et contre-mesures

| # | Risque | Contre-mesure |
|---|---|---|
| R1 | Mot de passe collé puis tapé fuit dans le fichier history | Blocklist apps (1Password, Bitwarden, etc.) — *idem* clipboard. Heuristique entropie : si la suggestion contient un mot ≥16 chars sans espace ni voyelle prédominante, on skip l'enregistrement |
| R2 | Clé Keychain perdue (Mac restauré, nouveau user) → fichier illisible | Au load, si déchiffrement échoue : drop le fichier en silence, repartir from scratch. Logger `history_decrypt_failed` sans détails |
| R3 | Bias trop fort → suggestions plagient l'historique mot-à-mot, jamais de variation | Cap slider à 2.0 sur log-prob. À slider max, le bias atteint l'équivalent d'un rerank top-3 vers les n-grammes connus, pas une substitution. Tester en bench que la diversité ne s'effondre pas |
| R4 | LogitProcessor MLX a une API qui change entre versions | Pin mlx-swift-examples à la version actuelle dans Package.resolved (déjà fait). Tester sur le 1B et le 1.5B Instruct |
| R5 | Latence accrue par lookup n-gram à chaque token | Trigramme stocké en `[UInt64: Float]` (token IDs hashés). Lookup O(1). Bench Si > 5ms par token → recoder en C ou downgrade à bigrammes only |
| R6 | Fichier history grossit, performance dégrade | Ring buffer 200 entrées, ~50 KB. Au-delà, rotation FIFO. Audit la taille au load et tronquer si >1 MB (corruption) |
| R7 | L'utilisateur croit que ses données sont envoyées au cloud (peur normale) | UI Préférences > Personnalisation affiche en clair l'emplacement du fichier, le chiffrement, et la liste "0 connexion réseau pour cette feature". Onboarding séparé au premier toggle ON |
| R8 | "Voir mes données" fenêtre est elle-même un vector si screenshot fuit | Désactiver les screenshots système sur cette fenêtre via `NSWindow.sharingType = .none`. Ajouter watermark "données privées" en footer |
| R9 | Bench injuste si history est vide (slider max sans données = aucun bias) | Bench harness peut prépopuler history avec un corpus synthétique FR (10-20 phrases types) avant de mesurer |
| R10 | NSSpellChecker.shared appelée depuis le bias path → contention thread | NgramBiaser est un acteur séparé, le sampler MLX tourne sur son thread inférence ; le bias se calcule à partir du modèle n-gram **précompilé** (pas de spell check live) |

## Découpage en 4 phases

Séquentiel A → D. C est la phase qui peut foirer (MLX LogitProcessor surface) — on se garde un fallback "bias appliqué post-sampling" en filet de sécurité.

---

### Phase 3.X.A — TypingHistoryStore chiffré (1 jour)

**But** : enregistrer proprement les acceptations Tab, chiffré, blocklisté, testable. Pas encore d'effet sur les suggestions — juste de la collecte.

**Livrable**
- `Sources/SouffleusePersonalization/TypingHistoryEntry.swift`
  ```swift
  public struct TypingHistoryEntry: Codable, Sendable {
      public let timestamp: Date
      public let contextBefore: String   // last 50 chars of prefix, sentence-trimmed
      public let accepted: String        // the suggestion the user accepted
      public let bundleID: String?       // for stats only, not used by bias
  }
  ```
- `Sources/SouffleusePersonalization/KeychainKey.swift` — wrapper minimal pour stocker/lire une clé AES-GCM 256-bit dans le Keychain login (`kSecClassGenericPassword`, account=`dev.cocotypist.Souffleuse.history`).
- `Sources/SouffleusePersonalization/TypingHistoryStore.swift` — actor :
  ```swift
  public actor TypingHistoryStore {
      public init(fileURL: URL = ...defaultURL)
      public func load() async
      public func append(_ entry: TypingHistoryEntry) async
      public func recentEntries(limit: Int) async -> [TypingHistoryEntry]
      public func clear() async
      public func count() async -> Int
      public func sizeBytes() async -> Int
  }
  ```
  - Chiffrement : `CryptoKit.AES.GCM` avec clé Keychain
  - Ring buffer 200 entrées en mémoire, flush à chaque append
  - File path : `~/Library/Application Support/Souffleuse/history.aes`
- `Sources/Souffleuse/SouffleuseAppDelegate.swift` modifié :
  - Au `.tab` accept LLM : si toggle ON ET bundleID ∉ blocklist → `Task { await history.append(...) }`
  - **Pas** sur typo accept (c'est de la correction, pas du style)
  - Filtre heuristique : si `accepted.count < 3` ou contient `[a-zA-Z0-9]{16,}` (token-like) → skip
- `Sources/Souffleuse/PreferencesStore.swift` :
  ```swift
  var personalizationEnabled: Bool { ... }   // défaut false
  var personalizationStrength: Double { ... } // 0.0 → 2.0, défaut 1.0
  let history = TypingHistoryStore()
  ```

**Edge cases**
- Keychain inaccessible (sandbox, locked) → toggle reste OFF, log `history_keychain_unavailable`
- Fichier corrompu (déchiffrement échoue) → drop, recommence vide, log `history_decrypt_failed`
- App quitte avant flush → on flush synchrone à chaque append (vs batch) pour J3
- Disk full → catch IOError, log `history_write_failed`, désactive la collecte pour la session

**Test acceptance**
```bash
swift test  # Tests round-trip chiffré, ring buffer rotation, blocklist
```
- Tests à ajouter dans `SouffleuseTests.swift` :
  - `historyEncryptedRoundTrip` : append 5 entries, recharge le store depuis le fichier, vérifie qu'on relit les 5
  - `historyRingBufferRotatesAt200` : append 250, vérifie count==200 et que les 50 premières sont droppées
  - `historyBlocksHighEntropyAcceptances` : try append avec accepted="aXz9Kpq7vBnM2Lqw4Rt6", vérifie qu'il est rejeté
  - `historyDecryptCorruptFileResetsToEmpty` : écrit 100 bytes random dans le fichier, init store, count==0
- Audit manuel : `xxd history.aes | head -2` → aucun caractère ASCII visible (chiffrement OK)

**Commit attendu** : `Jalon 3.X.A: TypingHistoryStore chiffré (AES-GCM + Keychain) + blocklist + tests`

---

### Phase 3.X.B — Modèle n-gram en mémoire (0.5 jour)

**But** : transformer les entries en distribution bigrammes/trigrammes utilisable pour le bias logit.

**Livrable**
- `Sources/SouffleusePersonalization/NgramModel.swift` — actor :
  ```swift
  public actor NgramModel {
      // Token IDs (Int) pas strings — on bias des logits, donc on raisonne dans
      // l'espace tokens du tokenizer actif.
      public init()
      public func ingest(tokens: [Int])     // appelé après tokenisation d'un entry
      public func clear()
      /// Retourne log-prob du prochain token sachant les 1-2 précédents.
      /// 0 si la séquence n'a jamais été vue (bias neutre, pas négatif).
      public func logProb(nextToken: Int, given: [Int]) -> Float
  }
  ```
- Implémentation : `[UInt64: UInt32]` pour les comptes (bigram=2 tokens packés, trigram=3 tokens packés via XOR hashing). Lissage Laplace léger.
- **Pas de persistance** : le n-gram model est reconstruit en mémoire au load du history store (ingestion de toutes les entries existantes). 200 entries × ~10 tokens = ~2000 token streams → reconstruction en <50ms.

**Edge cases**
- Tokenizer change entre 2 lancements (utilisateur switch de modèle) → invalider le modèle, rebuild from history. Tag chaque NgramModel par hash du tokenizer name.
- Entry avec accepted vide → skip
- Vocabulary tokenizer > 2^32 (impossible pour Qwen/Gemma) → assert en debug

**Test acceptance**
- `ngramReturnsHigherProbForSeenSequence` : ingest [1,2,3,4,1,2,3,4,1,2,3,4], `logProb(4, given: [2,3])` >> `logProb(99, given: [2,3])`
- `ngramReturnsZeroForUnseenSequence` : ingest [1,2,3], `logProb(99, given: [10,20])` == 0
- `ngramClearResetsModel` : ingest + clear → tous les lookups → 0

**Commit attendu** : `Jalon 3.X.B: NgramModel actor (bigram + trigram) + reconstruction online`

---

### Phase 3.X.C — LogitProcessor MLX + intégration sampler (1 jour)

**But** : faire effectivement bouger les logits du modèle au moment de la génération. C'est la phase risquée car MLX peut avoir des contraintes thread/Sendable.

**Livrable**
- `Sources/SouffleusePersonalization/NgramLogitBias.swift` :
  ```swift
  import MLX
  import MLXLMCommon

  public final class NgramLogitBias: LogitProcessor, @unchecked Sendable {
      private let model: NgramModel
      private let strength: Float
      private var contextTokens: [Int] = []  // accumule pendant la génération

      public init(model: NgramModel, strength: Float)

      public func process(logits: MLXArray) -> MLXArray {
          // 1. Récupère contextTokens.suffix(2) comme "given"
          // 2. Pour chaque token candidat (top-K logits, K=20 pour limiter coût),
          //    récupère logProb du n-gram, ajoute strength * logProb au logit
          // 3. Retourne MLXArray modifié
      }

      public func didSample(token: MLXArray) {
          // Append token au contextTokens (sera 1 token)
      }
  }
  ```
- `Sources/Souffleuse/PredictorViewModel.swift` :
  - Reçoit un `personalizationStrength` (depuis PreferencesStore via AppDelegate)
  - Au moment de construire `GenerateParameters`, si `strength > 0` et n-gram model non-vide :
    ```swift
    let bias = NgramLogitBias(model: ngramModel, strength: Float(strength))
    params.processor = bias  // ou append à la chain si MLX supporte
    ```
  - Sinon : params sans bias (comportement actuel)

**Surface MLX à valider en début de Phase C** (timeboxer 1h, sinon fallback)
- `LogitProcessor` est-il bien le protocole exposé publiquement dans MLXLMCommon ?
- `GenerateParameters.processor` est-il single ou chain ?
- `didSample(token:)` est-il sur le bon thread (sampler thread, pas main) ?

**Fallback si LogitProcessor cassé** : faire le bias **post-sampling** sur le best token via une wrapper du sampler. Moins propre, mais marche : on intercepte le top-K candidats, on les rerank avec n-gram strength, on rétourne le winner. Tout dans PredictorViewModel, pas besoin de toucher l'API MLX.

**Edge cases**
- `contextTokens` croît sans fin → cap à 32 tokens (matches notre repetitionContextSize)
- Strength = 0 → fast path : retourner logits sans modif
- N-gram model vide → idem
- Premier token de génération (pas de contexte précédent) → use le suffix des prompt tokens si dispo, sinon bias neutre

**Test acceptance**
- `biasModifiesLogitsTowardsKnownNgrams` : ingest [1,2,3,4,1,2,3,4], strength=2.0, fake logits uniformes 50d → après process, logit[4] est strictement plus grand que logit[99] (le n-gram a "voté")
- `biasZeroStrengthIsNoop` : strength=0 → logits identiques in/out
- Bench latence : process call sur logits 32k vocab → <5ms p95
- Test bout-en-bout (manuel via SouffleuseBench) : prompt "Bonjour, je m'appelle " → vérifier que la suggestion contient "Gabriel" ou ce que tu as accepté dans history

**Commit attendu** : `Jalon 3.X.C: NgramLogitBias (LogitProcessor MLX) + intégration sampler`

---

### Phase 3.X.D — Préférences > Personnalisation + bench A/B (0.5 jour)

**But** : exposer les contrôles, fournir l'audit user-side, mesurer si ça marche vraiment.

**Livrable**
- `Sources/Souffleuse/PreferencesWindow.swift` : nouvel onglet **Personnalisation** (6e onglet)
  ```
  ┌─────────────────────────────────────────────────┐
  │ Personnalisation                                │
  ├─────────────────────────────────────────────────┤
  │ ☑ Apprendre de mes frappes                      │
  │   Stocké chiffré localement, jamais envoyé.    │
  │                                                 │
  │ Influence  Off ──────●─── Max                  │
  │                                                 │
  │ 142 entrées collectées · 18 KB                  │
  │                                                 │
  │ [ Voir mes données ]  [ Tout supprimer… ]      │
  └─────────────────────────────────────────────────┘
  ```
- Compteur live (entries, bytes) — rafraîchi à chaque ouverture de l'onglet
- "Voir mes données" → nouvelle fenêtre `HistoryViewerWindow.swift` qui affiche les N dernières entries en clair (`contextBefore` + `accepted` + bundleID) dans un NSTableView. `sharingType = .none` pour bloquer les screenshots.
- "Tout supprimer" → `NSAlert` confirm → `await history.clear()` + `KeychainKey.delete()` → compteur retombe à 0
- Premier ON du toggle → modal d'onboarding :
  > "Souffleuse va enregistrer les phrases que tu acceptes (Tab) pour personnaliser tes futures suggestions. Les données sont chiffrées sur ton Mac et jamais envoyées sur internet. Tu peux les consulter ou les supprimer à tout moment depuis cet onglet."
  > [Annuler] [Activer]

- `Sources/SouffleuseEnrichmentBench/main.swift` — étendre avec une `--personalization-ab` flag :
  - Charge un corpus FR de 30 prompts depuis `Resources/bench-prompts-fr.txt`
  - Pour chaque prompt, génère 2x : sans bias / avec bias (strength=1.5, history pré-populée de 50 entries synthétiques cohérentes avec le corpus)
  - Mesure : longueur sortie, similarité lexicale entre sortie et "gold" attendu, présence de mots du history
  - Output JSONL dans `dist/bench-personalization-AB.jsonl`
  - Résumé console : "Acceptation simulée : sans=42% / avec=58% (+16pp)"

- `BENCHMARKS.md` : ajouter section "Personnalisation Jalon 3.X" avec :
  - Méthodo
  - Hardware / modèle utilisés
  - Tableau résultats
  - Verdict (≥5pp pour valider, sinon retourner aux paramètres)

- `audit.sh` étendu :
  ```bash
  echo "=== 5. No raw read of history.aes outside HistoryViewer ==="
  hits=$(grep -rn --include="*.swift" "history.aes" "${SHIPPING_DIRS[@]}" \
    | grep -v "HistoryViewerWindow\|TypingHistoryStore\|NgramModel" || true)
  if [ -n "$hits" ]; then red "FAIL: history.aes lu hors path autorisé"; ...; fi
  ```

- `ARCHITECTURE.md` §5.bis : nouvelle section "Persistance de texte utilisateur (Jalon 3.X+)"
  - Threat model : un attaquant local lit `history.aes` → bloqué par AES-GCM + clé Keychain
  - Attaquant avec accès Keychain → peut tout déchiffrer, accepté (c'est le contrat macOS)
  - Backup Time Machine → fichier chiffré sauvegardé tel quel, clé Keychain incluse dans le backup login → restauration OK sur le même Mac, illisible sur un autre
  - iCloud Keychain → la clé sync potentiellement entre les Macs de l'utilisateur. Décision : **on accepte** (c'est l'attente Apple), mais on document explicitement

**Edge cases**
- Onboarding modal montré une seule fois (flag `personalizationOnboardingShown` dans UserDefaults)
- HistoryViewer ouvert pendant que la collecte est OFF → afficher "Aucune donnée (la collecte est désactivée)"
- Slider à 0 mais collecte ON → continuer à collecter mais bias neutre (utilisateur "regarde" sans appliquer)
- Bench A/B avec history vide → afficher avertissement, prépopuler avec corpus de démo

**Test acceptance**
1. Toggle ON → onboarding modal s'affiche → Activer → entries commence à 0
2. Taper 5 phrases dans Notes, accepter Tab à chaque fois → compteur passe à 5
3. "Voir mes données" → tableau montre les 5 entries en clair, lecture des bundleID
4. "Tout supprimer" → confirm → compteur retombe à 0, fichier disparu, clé Keychain supprimée
5. `xxd ~/Library/Application\ Support/Souffleuse/history.aes` → caractères non-ASCII (chiffré)
6. `swift run SouffleuseEnrichmentBench --personalization-ab` → JSONL généré, delta acceptation rapporté
7. `bash audit.sh` → AUDIT PASSED (nouvelle check #5 incluse)

**Commit attendu** : `Jalon 3.X.D: Préférences Personnalisation + viewer + delete all + bench A/B`

---

## Hors scope Jalon 3.X (reportés J4+)

- Vraie fine-tuning LoRA sur l'historique (gros chantier, post-v1 confirmé)
- Bias adaptatif par contexte (différents biais selon bundle ID / heure / langue détectée)
- Détection automatique des changements de style ("tu écris un mail FR formel, je biaise différemment d'un message Slack")
- Sync iCloud explicite de l'historique entre Macs (la clé Keychain sync déjà via iCloud Keychain si activé, c'est suffisant)
- Export utilisateur de l'historique (JSON déchiffré pour audit)
- Import depuis Cotypist ou autres outils similaires
- Compression du modèle n-gram pour stockage persistant (pas utile tant qu'on reconstruit en <50ms au chargement)

## Estimation totale

3-3.5 jours dev solo. Phase la plus risquée : 3.X.C (surface MLX LogitProcessor — prévoir 1h en début pour timeboxer la validation API). Phase la plus stratégique : 3.X.D (le bench A/B est ce qui valide ou non que la perso améliore vraiment, sinon on retourne au mécanisme).

## Critères pour passer Jalon 3.X → Jalon 3.D

- Tous les tests d'acceptance des 4 phases passent
- `audit.sh` (avec check #5) → AUDIT PASSED
- Bench A/B → **delta acceptation ≥ 5pp** documenté dans BENCHMARKS.md
- Test utilisateur réel : activer la collecte 3 jours, observer que les suggestions utilisent les noms/formules récurrentes de l'utilisateur
- ARCHITECTURE.md §5.bis à jour avec le threat model étendu

Si delta < 5pp après tuning du slider : décider — soit on garde mais avec strength conservateur par défaut (0.5), soit on coupe la feature de v0.3 et on attaque 3.D direct.

## Prochain commit attendu après ce plan

```
git checkout jalon-3
# Toujours sur la même branche, on enchaîne 3.X.A
# (pas de nouvelle branche — 3.X est un add-on de 3.C)
swift package add target SouffleusePersonalization
# Implémenter Phase 3.X.A
git add Sources/SouffleusePersonalization/ Sources/Souffleuse/SouffleuseAppDelegate.swift Sources/Souffleuse/PreferencesStore.swift Tests/SouffleuseTests/SouffleuseTests.swift Package.swift
git commit -m "Jalon 3.X.A: TypingHistoryStore chiffré (AES-GCM + Keychain) + blocklist + tests"
```

## Contexte minimal pour reprendre cold après /clear

Si tu es l'agent qui reprend après un clear de contexte :
- Branche actuelle : `jalon-3`
- Dernier commit : `4404638` (Gemma défaut, Qwen Instruct dispo)
- Tu démarres la **Phase 3.X.A** ci-dessus
- Pas besoin de relire les commits précédents — tout ce qu'il faut savoir est dans ce fichier et dans `ARCHITECTURE.md`
- L'utilisateur est `meffysto@gmail.com`, francophone, sur Mac (probablement M-series)
- Quand l'utilisateur dit "test", il fait `make-app.sh` puis lance le binaire ; il revient avec un screenshot s'il voit un bug
- Ne pas changer Gemma comme défaut, c'est sa préférence explicite
- Custom Instructions actives dans l'app : "je suis Gabriel" (visible dans les suggestions précédentes)

## Backlog — Option B : few-shot dynamique depuis l'historique (V2)

> Décidé 2026-05-23 après bench utilisateur "Cotypist suggère mieux dans les mêmes 2-4 mots". Diagnostic : `gemma-3-1b-pt-4bit` (base) ignorait le system prompt. Fix v1 livré : passage à `gemma-3-1b-it-4bit` + détection langue locale (NLLanguageRecognizer) + system prompt steering FR/EN + temperature 0.4→0.25. À mesurer avant de décider si B est encore nécessaire.

**Idée** : à chaque `predict()`, piocher 2-3 entrées récentes acceptées dans `TypingHistoryStore` et les sérialiser comme few-shot examples dans le system message. Au lieu de biaiser les logits via `NgramLogitBias` (Phase 3.X.B), on biaise via in-context learning — c'est ce que font Copilot/Cursor.

**Avantages vs n-gram bias** :
- Capture des dépendances longues (le n-gram bigramme rate les patterns > 2 tokens)
- Pas de tokenizer-dependent state à rebuild quand on swap de modèle
- Le modèle "comprend" le style au lieu de "le subir" via logits

**Inconvénients** :
- +100-200 tokens dans le prompt → TTFT légèrement plus haut
- Sensible au choix des exemples : pioche bête = bias bête
- Risque de fuite : si l'utilisateur a tapé un mot de passe puis l'a accepté en suggestion, on pourrait le re-suggérer dans un autre contexte

**Pré-requis** :
- TypingHistoryStore en place (livré en 3.X.A)
- Toggle "Apprendre de mes frappes" ON
- ≥ 20 entrées dans l'historique pour que la pioche soit pertinente

**Critère de pioche** (à raffiner) :
- Score par similarité de `contextBefore` au `userTail` actuel (embedding ou simple Jaccard de tokens)
- Top 2-3 par score, exclusion stricte des entrées du même bundleID que les blocklists sensibles
- Cap dur sur la longueur cumulée des examples (200 tokens max)

**Format dans le system prompt** :
```
Here are recent examples of how this user continues their text. Mimic their style:

Input: {contextBefore_1}
Output: {accepted_1}

Input: {contextBefore_2}
Output: {accepted_2}
```

**Critère d'arrêt** : delta acceptation mesurable vs v1 (post-IT-switch) sur un bench harness FR de 30+ prompts. Si < 3pp, on garde n-gram bias (3.X.B) comme seule perso et on ferme B.
