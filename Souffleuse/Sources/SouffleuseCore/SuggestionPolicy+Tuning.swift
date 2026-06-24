import Foundation

extension SuggestionPolicy {
    /// Constantes tunables centralisées pour le Ghost Relevance Gate (D-06..D-13).
    ///
    /// **Single source of truth.** Pitfall 6 (RESEARCH §"Common Pitfalls") :
    /// aucun seuil littéral ne doit apparaître ailleurs dans le code ou les
    /// tests — toujours via `SuggestionPolicy.Tuning.*`. Le grep CI en fin
    /// de plan (Task 4) refuse tout literal de la liste D-06..D-09 hors de
    /// ce fichier.
    ///
    /// Visibilité `internal` (pas `private`) : les tests accèdent via
    /// `@testable import Souffleuse`.
    public enum Tuning {
        // MARK: - D-07 Gate floor + replacement bar
        public static let gateFloor: Float = 0.25
        public static let replacementBar: Float = 1.15

        /// `MW_ECHO_RUN` — longueur min (en mots) d'un run VERBATIM recopié du tail
        /// pour qu'un ghost soit jugé « écho/boucle » et gaté. **Défaut 4** (calibré
        /// par `SouffleuseEchoEval`, 2026-06-08). Le garde sac-de-mots seul
        /// (`echoScore ≥ continuationEchoThreshold`) tuait ~50% de BONS ghosts qui
        /// réutilisent simplement du vocabulaire du contexte (« lancer le serveur »,
        /// « m'organiser », « beurre » à s=1.00) ; ce 2ᵉ critère POSITIONNEL ne gate
        /// que les vraies répétitions verbatim (≥4 mots contigus, ex. la boucle
        /// « à savoir si la radioactivité » recrachée telle quelle), récupérant les
        /// bons ghosts sans laisser passer une seule boucle (3/3 contrôles). Mettre
        /// `MW_ECHO_RUN=0` ⇒ comportement d'origine (gate sur le seul sac-de-mots).
        public static var echoMinVerbatimRunWords: Int {
            if let s = ProcessInfo.processInfo.environment["MW_ECHO_RUN"], let v = Int(s) { return max(0, v) }
            return 4
        }

        /// `MW_ECHO_RUN_STANDALONE` — seuil du garde verbatim AUTONOME (non gaté par
        /// `echoScore`) appliqué dans `beamPostFilter` : un run verbatim ≥ ce nombre
        /// de mots recopié du tail est TRONQUÉ quoi qu'il arrive. Couvre le cas où
        /// `echoScore` (sac-de-mots sur la DERNIÈRE phrase) est dilué par un point
        /// récent (« …mieux. il faut » → dernière phrase « il faut » ⇒ score < 0.5,
        /// le garde gaté ne se déclenche pas) alors que le ghost recopie une longue
        /// boucle. Plus HAUT que `echoMinVerbatimRunWords` (4) pour zéro faux positif
        /// sans le filet sac-de-mots. **Défaut 5.** `MW_ECHO_RUN_STANDALONE=0` désactive.
        public static var standaloneEchoRunWords: Int {
            if let s = ProcessInfo.processInfo.environment["MW_ECHO_RUN_STANDALONE"], let v = Int(s) { return max(0, v) }
            return 5
        }

        // MARK: - D-08 Routing thresholds
        ///
        /// Tightening pass 2026-05-26 (post 04-07 empirical validation):
        /// raised from 0.4 → 0.6 after observing that history substring matches
        /// were polluting after-space contexts ("Je reviens " → "Je suis…" stale
        /// injection). A 0.4 bar lets too many low-relevance history fragments
        /// through. Local completions or LLM generations should win unless
        /// history is highly confident.
        public static let afterSpaceL1Bar: Float = 0.6

        /// Runtime-overridable variant. Reads `SOUFFLEUSE_REPLAY_L1_BAR` env
        /// (parsable Float) and returns it; otherwise returns `afterSpaceL1Bar`.
        /// Used by `SuggestionPolicy` L1 gate so offline replay can A/B
        /// different L1 thresholds without recompiling. Production runtime
        /// without the env var sees the unchanged 0.6 threshold.
        public static var afterSpaceL1BarRuntime: Float {
            if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_REPLAY_L1_BAR"],
               let f = Float(s) { return f }
            return afterSpaceL1Bar
        }

        /// L0 system word-completer (mid-word instant fill) — **PAUSED / OFF by
        /// default** (2026-05-29). Its frequency-ranked pick shows the wrong word
        /// mid-ambiguity ("est inf" → "informations" instead of "informée") and
        /// blocks the LLM's context-correct completion. Disabled for now so the
        /// context-aware LLM owns mid-word; re-enable for A/B by setting
        /// `SOUFFLEUSE_WORDCOMPLETER=1`. (The LLM-only mid-word path still has its
        /// own open issues — repetition/fragments — tracked separately.)
        public static var wordCompleterEnabledRuntime: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_WORDCOMPLETER"] != nil
        }

        public static let l2UpgradeDelta: Float = 0.15

        /// **Solution C — mid-word L2 overrides L0 word-complete.** When `true`,
        /// an LLM chunk that passes the admit gate mid-word replaces a
        /// `.wordComplete` ghost regardless of the lengthFit-based replacement
        /// bar. The spell-checker (L0) is context-blind and often picks the wrong
        /// word ("inv"→"invite" instead of "investissement"); the admitted LLM
        /// chunk is context-aware and already passed the dictionary admit gate, so
        /// it wins. Set to `false` to revert to requiring the full bar for L0
        /// ghosts too.
        public static let midWordL2OverridesWordComplete: Bool = true

        /// Few-shot prose injection into the live llama prompt (B-prompt,
        /// 2026-05-30). When true AND personalization is on, PVM retrieves the
        /// user's own `.prose` history entries (never accept-fragments) and
        /// `LlamaPromptBuilder.buildLlamaPrompt` injects them as a raw
        /// demonstration block ahead of the caret text. The SouffleuseInjectionEval
        /// A/B/C probe showed this anchors the base model to the user's
        /// register/domain and suppresses off-topic hallucination without the
        /// multi-greeting cross-pollution that motivated the original removal
        /// (PVM:600-609). Flip to false to restore sampler-only personalization
        /// (the llama corpus n-gram bias) with no demonstration text in the prompt.
        /// Kill-switch runtime `SOUFFLEUSE_EXAMPLES_OFF` (pattern *_OFF maison) :
        /// sert l'A/B « tête de prompt stable vs re-rankée par frappe » — le bloc
        /// étant en TÊTE du prompt, tout changement de ranking invalide le
        /// prefix-cache KV du beam (seeds « partiels » mesurés 244 ms vs 83 chauds).
        public static var examplesInjectionEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_EXAMPLES_OFF"] == nil
        }

        /// **Style primer** (étage 2 du plan primer, 2026-06-12) : préfixe le
        /// `ctxPrefix` du prompt BEAM avec 1-2 proses passées de l'utilisateur
        /// (même cluster, accordées au ton par app via `ToneStore`, pauvres en
        /// entités distinctives — sélection `StylePrimer.block`). Le bench
        /// `SouffleusePrimerBench` (A/B/C/D) a mesuré : accordé-neutre ΔlogP
        /// +2.16 vs sans primer (7/8), accord de registre +4.12 vs désaccordé
        /// (7/8), 0 contamination / 0 écho / 0 bascule de registre. **OPT-IN
        /// runtime** (`SOUFFLEUSE_STYLE_PRIMER=1`) tant que l'A/B d'acceptance
        /// live n'a pas tranché : défaut = chemin actuel byte-identique.
        public static var stylePrimerEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_STYLE_PRIMER"] != nil
        }

        /// **Bias corpus dans le beam** (étage « mots », 2026-06-12) : applique
        /// le boost suffix-array/n-gram de personnalisation (nucleus gate + tier
        /// promotion, calibration greedy 25/25 recall · 0/33 sur-injection,
        /// LlamaEngine.swift:489-514) dans la boucle d'expansion du
        /// `BeamGhostEngine` — le chemin LLM ACTIF, où ce biais n'existait pas
        /// (le rappel génératif des termes appris était mort depuis le passage
        /// au beam core). Dépend de `beamCoreEnabled` (pas de beam ⇒ pas de
        /// bias beam) et gated en aval par `personalizationStrength > 0`.
        /// **OPT-IN runtime** (`SOUFFLEUSE_BEAM_BIAS=1`) tant que
        /// `SouffleuseBeamBiasEval` et l'essai live n'ont pas tranché :
        /// défaut = expansion beam byte-identique (biasStrength 0, zéro lookup).
        public static var beamBiasEnabled: Bool {
            beamCoreEnabled && ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM_BIAS"] != nil
        }

        /// **Token-healing master switch (Task 1 + Task 2).** When `true`, a
        /// mid-word caret feeds the trailing partial word to the engine as a
        /// `healPrefix` so the model re-derives the WHOLE word from a clean
        /// boundary (engine drops the partial token + masks the first generated
        /// tokens to be prefix-compatible). `onLLMChunk` then ADMITS the healed
        /// chunk when `partial + leadingPlainRun(chunk)` forms a valid dictionary
        /// word, instead of blocking it as a "guess". Set to `false` to revert to
        /// the un-healed behaviour byte-for-byte (engine default `healPrefix: nil`
        /// + the original "complete word ≥4 chars" admit rule).
        public static let midWordHealingEnabled: Bool = true

        /// **Corpus recall quality-gate (Task 4).** When `true`, a strong-corpus
        /// instant recall whose continuation (after `capToWords`) ends mid-word on
        /// an INCOMPLETE fragment — and is not sentence-terminated — is rejected so
        /// the cascade falls through to the LLM. Stops a truncated stored phrase
        /// ("… il est indiqué s'ils report") from pre-empting a better LLM
        /// generation via the unbeatable `strongCorpusSourcePrior`. Conservative:
        /// only clearly-broken recalls are rejected; good recalls keep the speed
        /// win. Set to `false` to revert to always emitting any strong recall.
        public static let corpusRecallQualityGateEnabled: Bool = true

        // MARK: - Phase 3 (b) — Cotypist "short" fast-path (strong corpus match)
        ///
        /// Minimum matched-context length (in characters) for a corpus
        /// continuation to be shown DIRECTLY as the ghost with zero LLM
        /// inference. Below this we treat the match as too weak and let the
        /// L1/L2 cascade decide. 6 chars is enough to catch short after-space
        /// openers like "Merci " and "Bonjour, " at Cotypist-like latency while
        /// still refusing bare fragments such as "Bonj" or "co".
        public static let strongCorpusMatchMinChars: Int = 6

        /// `MW_STRONG_MINCHARS` — seuil after-space du strong-corpus, override live
        /// (A/B sans rebuild, même pattern que `afterSpaceL1BarRuntime` /
        /// `escBranchKRuntime`). Env absente ⇒ la constante (6). Clampé ≥ 1 pour
        /// qu'une valeur dégénérée ne désactive pas la garde de longueur min.
        public static var strongCorpusMatchMinCharsRuntime: Int {
            if let s = ProcessInfo.processInfo.environment["MW_STRONG_MINCHARS"], let v = Int(s) { return max(1, v) }
            return strongCorpusMatchMinChars
        }

        /// Mid-word variant of the threshold above. When the caret sits INSIDE a
        /// word, the in-progress fragment plus its preceding context recalls a
        /// learned phrase that completes the word — Cotypist parity: "Bonjour,
        /// co" → "mment allez-vous ?". This fires on a SHORTER matched context
        /// (the after-space 16-char bar would never trigger on "Bonjour, co" =
        /// 11 chars) but stays safe two ways: the matched needle still has to
        /// reach this length (so a bare 2-letter fragment with no context never
        /// recalls anything), and the continuation must START with a letter (it
        /// genuinely completes the current word rather than jumping to a new
        /// one). 8 ≈ one short word of leading context + the fragment.
        public static let midWordCorpusMatchMinChars: Int = 8

        /// Minimum length of the (complete) current partial word for a mid-word
        /// LLM continuation to be allowed (Option A refined, 2026-05-27). Below
        /// this, a "complete" word is most likely a short fragment the
        /// NSSpellChecker false-accepts ("es", "pr", "pu", "v") that would let
        /// the model guess the wrong word or drift to another language. ≥4 keeps
        /// real finished words ("frais", "corrigé", "vendredi", "contrôle").
        public static let midWordLLMMinCompleteWordChars: Int = 4

        /// Source prior for a STRONG corpus fast-path match. Higher than the
        /// regular `.history` prior (0.75) so that a confident instant ghost is
        /// NOT clobbered by a divergent LLM stream — `onLLMChunk`'s replacement
        /// bar (1.15) requires the LLM to beat `≈0.92 × 1.15 ≈ 1.06`, which an
        /// in-[0,1] score can never reach. The LLM may therefore only EXTEND
        /// (never replace) a strong corpus ghost, honouring the anti-churn rule.
        public static let strongCorpusSourcePrior: Float = 0.92

        /// A mid-word corpus recall that commits FEWER than this many letters/
        /// digits of the word the user is still typing is a MICRO completion
        /// ("Rapport fis" → "c", "…2024" → "9", "qu" → "'a"). It is still shown
        /// INSTANTLY (with the normal strong prior, so it appears immediately),
        /// but `onLLMChunk` lets an admitted, gate-passing LLM completion of the
        /// WHOLE word REPLACE it freely — bypassing the lengthFit-based bar that
        /// a 1-word healed completion ("cal" → "fiscal") could otherwise never
        /// clear. At/above this committed length the recall is treated as a
        /// confident learned completion ("fiscalité", "comment allez-vous ?") and
        /// keeps the anti-churn bar. 3 ⇒ only 1–2 char completions are overridable.
        public static let corpusMicroCompletionMaxChars: Int = 3

        // MARK: - Mid-word escalation (greedy+dico → branches) — Frame C, flag OFF
        //
        // Mesuré de bout en bout sur le chemin de prod exact via
        // `SouffleuseMidwordEval` (greedy = passe de prod, mêmes bans + healing).
        // Étage 1 (greedy + dico) tranche 10/23 cas sans branche ; les branches
        // (étage 2) ne récupèrent que le milieu incertain. Tous les seuils ICI
        // (Pitfall 6) ; flag maître OFF → le seam reste `midword_block`, comportement
        // byte-identique à aujourd'hui.

        /// Master switch + kill-switch runtime. **OFF par défaut** (env absente) ⇒
        /// le mid-mot incomplet reste `midword_block` (rien affiché), comportement
        /// byte-identique à aujourd'hui. `SOUFFLEUSE_MIDWORD_ESCALATION=1` ⇒ l'étage 1
        /// (greedy + dico) décide ; les branches (F2) arriveront sous le même flag.
        /// Env-overridable (même pattern que `wordCompleterEnabledRuntime`) pour
        /// l'A/B et le revert instantané sans recompiler.
        public static var midWordEscalationEnabled: Bool {
            // ON par défaut (shippé). Kill-switch DEV : SOUFFLEUSE_MIDWORD_ESCALATION_OFF.
            ProcessInfo.processInfo.environment["SOUFFLEUSE_MIDWORD_ESCALATION_OFF"] == nil
        }

        // MARK: - No-context strict gate (KeyType empty-prefix parity)

        /// Garde stricte « pas de contexte ⇒ pas de ghost », parité KeyType.
        /// **OFF par défaut** (env absente) ⇒ le gate field-hint actuel reste seul,
        /// comportement byte-identique. `SOUFFLEUSE_NOCONTEXT_STRICT=1` ⇒ on bloque
        /// AUSSI quand le préfixe n'a pas de signal lexical réel
        /// (`SuggestionPolicy.hasLexicalContext`), MÊME avec un hint de champ faible
        /// (placeholder/role) — la cause n°1 des ghosts « fortune cookie ».
        /// Env-overridable pour l'A/B live sans rebuild (même pattern que les autres flags).
        public static var noContextStrictGateEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_NOCONTEXT_STRICT"] != nil
        }

        /// Nombre minimal de mots de CONTENU (non stop-word, ≥2 lettres) requis
        /// dans le préfixe pour autoriser une génération libre quand le gate strict
        /// est actif. 1 = au moins un vrai mot. Env `SOUFFLEUSE_NOCONTEXT_MINTOKENS`.
        public static var noContextMinContentTokens: Int {
            if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_NOCONTEXT_MINTOKENS"],
               let v = Int(s) { return max(1, v) }
            return 1
        }

        // MARK: - Blended retrieval (KeyType perso mix, count=1)

        /// Active le retrieval few-shot BLENDÉ (`rankBlended` : pertinence + récence
        /// + longueur) à la place du `rank` Jaccard-pur. **OFF par défaut** ⇒ le
        /// retrieval actuel (Jaccard top-K) reste, comportement byte-identique.
        /// `SOUFFLEUSE_BLENDED_RETRIEVAL=1` ⇒ parmi les exemples PERTINENTS (même
        /// filtre `minRelevanceScore`), on privilégie les démonstrations récentes et
        /// informatives — le levier perso qui marche dès count=1 (vs promotion n-gram
        /// qui exige count≥3).
        public static var blendedRetrievalEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_BLENDED_RETRIEVAL"] != nil
        }

        /// Poids du bonus de récence dans le blend (multiplicatif). `MW`-style env
        /// override pour l'A/B. 0.3 = un exemple le plus récent vaut jusqu'à +30 %.
        public static var retrievalRecencyWeight: Double {
            if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_RETRIEVAL_RECENCY"],
               let v = Double(s) { return v }
            return 0.3
        }

        /// Poids du bonus de longueur dans le blend. 0.2 = un exemple long
        /// (≥ saturation) vaut jusqu'à +20 %.
        public static var retrievalLengthWeight: Double {
            if let s = ProcessInfo.processInfo.environment["SOUFFLEUSE_RETRIEVAL_LENGTH"],
               let v = Double(s) { return v }
            return 0.2
        }

        /// Fast-accept : un mot greedy/healed valide ET prolongeant le partiel, à
        /// confiance top-1 ≥ ce seuil ET sur un fragment ≥ `escMinFastLen`, est
        /// montré DIRECT (0 branche). 0.85 = plancher mesuré : sous ce seuil un mot
        /// valide-mais-faux (P1 haut, ex. "Pode" sur "Po") fuit en fast-accept (le
        /// sweep `MW_FAST_P1=0.75` a montré 1 garbage affiché). À 0.85 : 0 garbage.
        public static let escFastP1: Double = 0.85

        /// Longueur min du fragment partiel pour un fast-accept. Un fragment court
        /// reste trop ambigu même à P1 haut ("Po" 2 chars → "Pode" confiant mais
        /// faux) → il doit passer par les branches. 4 ≈ assez de lettres pour que
        /// la complétion soit peu ambiguë ("cacahu" → "cacahuète").
        public static let escMinFastLen: Int = 4

        /// (F2) Nombre MAX de branches stochastiques pour trancher la zone
        /// incertaine (greedy valide mais P1 bas, ou fragment court). Early-exit
        /// dès qu'un mot atteint la majorité → souvent 2 suffisent.
        public static let escBranchK: Int = 3

        /// (F2) Température des branches. Le texte MONTRÉ reste le greedy
        /// déterministe ; les branches ne servent qu'à VOTER l'accord.
        public static let escBranchTemp: Float = 0.7

        /// (F2) Accord inter-branches minimal (mot modal / votes) pour montrer.
        /// Sépare le mot clair (≥0.6) du fragment ambigu (`co`/`Po` mesurés à 0.40).
        public static let escAgreeThresh: Double = 0.6

        /// (F1) Plafond de tokens de la passe greedy d'escalade : on ne veut que le
        /// mot courant + un poil. Court = latence bornée. Pris en `min()` avec le
        /// `maxTokens` de la requête. Mesuré sur `SouffleuseMidwordEval` : justesse
        /// du mot de tête IDENTIQUE de cap 3 à 8 (14/18) — les 5 tokens en plus
        /// n'apportent rien (on ne lit que le mot de tête, le P1 est sur le 1ᵉʳ
        /// token). 4 = −68 ms vs 8, avec 1 token de marge defrag sur la passe affichée.
        public static let escGreedyMaxTokens: Int = 4

        /// (F2) Plafond de tokens d'une BRANCHE — séparé du greedy. Mesuré sur
        /// `SouffleuseMidwordEval` : 8→3 tokens fait chuter le coût de 220→121 ms/
        /// branche (−99 ms, soit ~−300 ms sur K=3) pour −1/23 de justesse seulement.
        /// La branche n'a besoin que du mot de tête (1-3 tokens), pas d'une suite.
        public static let escBranchMaxTokens: Int = 3

        /// (F1) Epsilon de `minFirstTokenProb` pour FORCER le calcul de la confiance
        /// top-1 sans jamais aborter (le moteur ne calcule le softmax que si > 0).
        /// Si bas qu'aucun token réel ne tombe dessous → sortie greedy inchangée.
        public static let escFirstTokenProbEpsilon: Double = 0.0001

        // Variantes runtime-overridables des knobs branches (A/B live sans rebuild,
        // même pattern que `afterSpaceL1BarRuntime`). Env absente → la constante.
        /// `MW_ESC_K` — nombre de branches.
        public static var escBranchKRuntime: Int {
            if let s = ProcessInfo.processInfo.environment["MW_ESC_K"], let v = Int(s) { return max(0, v) }
            return escBranchK
        }
        /// `MW_ESC_TEMP` — température des branches (plus bas = plus serré/convergent).
        public static var escBranchTempRuntime: Float {
            if let s = ProcessInfo.processInfo.environment["MW_ESC_TEMP"], let v = Float(s) { return v }
            return escBranchTemp
        }
        /// `MW_AGREE` — seuil d'accord pour montrer.
        public static var escAgreeThreshRuntime: Double {
            if let s = ProcessInfo.processInfo.environment["MW_AGREE"], let v = Double(s) { return v }
            return escAgreeThresh
        }

        // MARK: - F3 — Fallback L0 dico (mots fumblés par le 1B)
        //
        // Dernier recours QUAND l'escalade cache : le WordCompleter (NSSpellChecker)
        // complète un vrai mot du dico que le LLM rate (« pingou »→« pingouin »).
        // Borné fort pour neutraliser l'aveuglement au contexte qui l'avait fait
        // couper : seulement sur fragment long ET si la complétion COMMUNE des
        // candidats est nette (mot quasi-déterminé). Sinon → rien, comme aujourd'hui.

        /// Master switch F3, env-overridable. OFF par défaut. Ne tire QUE dans la
        /// branche escalade-cache → requiert aussi `midWordEscalationEnabled`.
        public static var midWordL0Fallback: Bool {
            // ON par défaut (shippé). Kill-switch DEV : MW_L0_OFF.
            ProcessInfo.processInfo.environment["MW_L0_OFF"] == nil
        }

        /// Longueur min du fragment partiel pour tenter le fallback dico. ≥4 :
        /// court = trop de candidats = complétion commune minuscule de toute façon.
        public static let escL0MinPartial: Int = 4

        /// Longueur min de la complétion COMMUNE pour la montrer. Sous ce seuil les
        /// candidats divergent trop tôt (ambigu) → on ne montre rien.
        public static let escL0MinCompletion: Int = 2

        // MARK: - Long-ghost mid-mot SIMPLIFIÉ (A/B contre l'escalade)
        //
        // Chemin alternatif au mid-mot : UNE seule passe greedy healed, post-
        // traitée par les MÊMES helpers `OutputFilter` que l'escalade, SANS vote
        // de branches, SANS fast-accept/fast-reject, SANS fallback dico (F3).
        // Sous le même seam `useMidWordEscalation` mais branché par le flag
        // ci-dessous. OFF par défaut → comportement byte-identique à l'escalade.

        /// Active le chemin mid-mot SIMPLIFIÉ (single greedy healed generate) à la
        /// place de `midWordEscalate`. **OFF par défaut** : ne devient `true` QUE si
        /// l'env `SOUFFLEUSE_MIDWORD_LONGGHOST_ON` est présente. Flag d'A/B : le
        /// chemin escalade complet (F1/F2/F3) reste inchangé tant qu'il est absent.
        public static var midWordLongGhostEnabled: Bool {
            // ON PAR DÉFAUT (endgame Phase A). Kill-switch `SOUFFLEUSE_LONGGHOST_OFF`
            // → revient à la cascade F1/F2/F3 sans rebuild (warm fallback). La cascade
            // reste dans le code jusqu'à la Phase B (suppression après confiance).
            ProcessInfo.processInfo.environment["SOUFFLEUSE_LONGGHOST_OFF"] == nil
        }

        /// Le **beam contraint** (`BeamGhostEngine`, K=2) est le SEUL chemin de
        /// génération LLM du ghost. ON ⇒ `predict()` route le cœur LLM vers le
        /// beam (mid-mot = `requiredPrefix`, après-espace = décode libre K=1 ≡
        /// greedy) ; le greedy long-ghost + le gradient d'engagement + le plancher
        /// dico ne sont PLUS appelés. La couche instant (recall/lexique/cache/
        /// perso, `routeInstant`) reste DEVANT, inchangée.
        /// **ON PAR DÉFAUT** (décision LATENCE-GHOST-HANDOFF §3 : les `launchctl
        /// setenv` ne survivaient pas au reboot → ghost silencieusement en
        /// cascade). Kill-switch `SOUFFLEUSE_BEAM_CORE_OFF` ⇒ retour cascade
        /// sans rebuild, pattern `midWordLongGhostEnabled`. Preuves : intention
        /// 64 % vs 29 %, accord 9/10 vs 4/10 (cf. BEAM-LLM-CORE-HANDOFF.md §1).
        public static var beamCoreEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM_CORE_OFF"] == nil
        }

        /// Par-dessus `beamCoreEnabled` : la **réserve de branches** entre
        /// frappes (`ghostWithReserve` + `advance(typedChar:)`). La frappe qui
        /// suit la tête du ghost devient un HIT (avance de pointeur, 0 décode,
        /// ~0 ms) ; une divergence re-beame (MISS, coût froid). Mesuré post-fix-
        /// routage : 74-76 % de HIT, coût amorti ~58 ms/frappe vs ~125 régénérés
        /// (SouffleuseBeamAmortizedEval + PARITY-FINDINGS).
        /// **ON PAR DÉFAUT** (même décision que `beamCoreEnabled`). Kill-switch
        /// `SOUFFLEUSE_BEAM_RESERVE_OFF` ⇒ génération fraîche glissante,
        /// indépendamment du kill-switch beam-core.
        public static var beamReserveEnabled: Bool {
            beamCoreEnabled
                && ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM_RESERVE_OFF"] == nil
        }

        /// `SOUFFLEUSE_GHOST_STREAM` — peint le longghost AU FIL des tokens (TTFT ~20 ms)
        /// au lieu d'attendre la génération complète (~300 ms, que la frappe suivante
        /// annulerait). OFF par défaut ⇒ one-shot d'origine, byte-identique.
        ///
        /// ⚠️ OBSOLÈTE depuis que le beam-core est le défaut (10/06) : son unique
        /// call-site vit dans la branche long-ghost/escalade, court-circuitée par
        /// `useBeamCore` (`if useBeamCore { … return }` dans PVM.predict). Le flag
        /// ne tire plus que sur le FALLBACK cascade (beam non chargé ou
        /// `SOUFFLEUSE_BEAM_CORE_OFF`). Le beam est one-shot par nature (le gagnant
        /// des K branches n'est connu qu'en fin de décodage) — un streaming beam
        /// serait une feature à concevoir, pas ce flag. Vérifié le 12/06.
        public static var ghostStreamEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_GHOST_STREAM"] != nil
        }

        /// `MW_STREAM_MIN` — nb de tokens minimum AVANT le premier partiel peint.
        /// Évite de flasher 1-2 tokens (« il faut plus que 2-3 tokens mid-mot ») : on
        /// attend un chunk consistant (~2-3 mots) puis on stream chaque token ensuite.
        /// Trop haut = on retombe vers le one-shot lent ; ~5 est l'équilibre.
        public static var ghostStreamMinTokens: Int {
            if let s = ProcessInfo.processInfo.environment["MW_STREAM_MIN"], let v = Int(s) { return max(1, v) }
            return 5
        }

        /// `MW_LG_MAXTOKENS` — plafond de tokens de l'unique passe greedy du long-
        /// ghost. Pris en `min()` avec le `maxTokens` de la requête. Défaut 14.
        public static var midWordLongGhostMaxTokens: Int {
            if let s = ProcessInfo.processInfo.environment["MW_LG_MAXTOKENS"], let v = Int(s) { return max(1, v) }
            return 14
        }

        /// `MW_LG_MAXWORDS` — nombre max de mots entiers conservés dans la
        /// continuation montrée. Défaut 4.
        public static var midWordLongGhostMaxWords: Int {
            if let s = ProcessInfo.processInfo.environment["MW_LG_MAXWORDS"], let v = Int(s) { return max(1, v) }
            return 4
        }

        // MARK: - Gradient d'engagement mi-mot (flag OFF) — 3 niveaux pilotés par
        // la cascade escalate EXISTANTE (P1 fast-accept + accord des k branches).
        //
        // Au lieu d'un long-ghost binaire montre/cache, on module la PROFONDEUR du
        // souffle selon l'incertitude du modèle, RÉUTILISÉE telle quelle depuis
        // `midWordFastDecision`/`midWordBranchDecision` (PAS d'entropie, PAS de
        // nouveau signal moteur) :
        //   PLEIN   : greedy ~maxWords + rolling refill autorisé (living ghost).
        //   PRUDENT : 1 mot (le modal), FIGÉ, rolling INTERDIT.
        //   ZÉRO    : abstient (rien montré).
        // Le gradient ne s'active QUE sous le flag ci-dessous ET à l'intérieur de la
        // branche long-ghost (`midWordLongGhostEnabled` ON). Flag ABSENT ⇒ chemin
        // long-ghost byte-identique à aujourd'hui (zéro changement de chemin).

        /// `MW_ENGAGEMENT` — active le gradient d'engagement mi-mot à 3 niveaux.
        /// **OFF par défaut** (env absente) ⇒ le long-ghost reste binaire montre/
        /// cache, byte-identique à aujourd'hui. Présent ⇒ le niveau d'engagement
        /// (PLEIN/PRUDENT/ZÉRO) est décidé par la cascade escalate sur le chemin
        /// long-ghost. Pattern identique aux autres flags d'A/B (`!= nil`).
        public static var midWordEngagementEnabled: Bool {
            ProcessInfo.processInfo.environment["MW_ENGAGEMENT"] != nil
        }

        /// `MW_ENG_PLEIN` — accord inter-branches minimal pour le niveau PLEIN
        /// (greedy ~maxWords + rolling). Défaut 0.8 : forte convergence des branches
        /// ⇒ on a confiance pour dérouler le souffle long ET le laisser rouler.
        public static var midWordEngagementPleinThresh: Double {
            if let s = ProcessInfo.processInfo.environment["MW_ENG_PLEIN"], let v = Double(s) { return v }
            return 0.8
        }

        /// `MW_ENG_PRUDENT` — accord inter-branches minimal pour le niveau PRUDENT
        /// (1 mot modal FIGÉ, rolling interdit). Défaut 0.5 : convergence moyenne ⇒
        /// on montre juste le mot modal, sans s'engager sur une suite ni rouler.
        /// Sous ce seuil ⇒ ZÉRO (abstention). Doit rester < `…PleinThresh`.
        public static var midWordEngagementPrudentThresh: Double {
            if let s = ProcessInfo.processInfo.environment["MW_ENG_PRUDENT"], let v = Double(s) { return v }
            return 0.5
        }

        /// `MW_DICO_FLOOR_OFF` — **plancher dico mid-mot. ON par défaut.** Quand le
        /// gradient d'engagement s'abstient (`.zero`) ALORS qu'un mot est EN COURS,
        /// on ne montre pas du vide : on complète le mot courant via NSSpellChecker
        /// (`WordCompleter.completion`, meilleur candidat qui PROLONGE le préfixe
        /// tapé). Garantit l'invariant « un mot valide à chaque lettre tant que le
        /// mot n'est pas fini » — la complétion se ré-évalue à chaque frappe, donc
        /// une approximation à 3 lettres se précise à 4+. Déterministe (<1ms, dico
        /// système), ghost FIGÉ (rolling interdit), et il ne fait que REMPLIR LE
        /// VIDE : jamais il ne remplace un souffle LLM PLEIN/PRUDENT. À une frontière
        /// (fin de phrase / pas de mot partiel) il ne se déclenche pas. Coupé par
        /// `MW_DICO_FLOOR_OFF` (retour à l'abstention pure du gradient).
        public static var midWordDicoFloorEnabled: Bool {
            ProcessInfo.processInfo.environment["MW_DICO_FLOOR_OFF"] == nil
        }

        // MARK: - Ghost ROLLING REFILL (sliding window, flag OFF) — parité Cotypist
        //
        // Au lieu d'un ghost fixe (3-4 mots) qui SE VIDE à mesure que l'utilisateur
        // tape dedans (comportement actuel), on maintient le ghost affiché à une
        // profondeur ~constante : on GÉNÈRE le(s) mot(s) suivant(s) à droite pendant
        // que l'utilisateur consomme à gauche — une fenêtre glissante qui se recharge
        // et ne disparaît jamais. Tous les seuils ICI (Pitfall 6). Flag maître OFF
        // par défaut ⇒ chemin entièrement gaté, comportement byte-identique.

        /// Master switch du mode rolling-refill. **OFF par défaut** : ne devient
        /// `true` QUE si l'env `SOUFFLEUSE_GHOST_ROLLING` est présente. Hors flag,
        /// le ghost se vide comme aujourd'hui (aucun refill émis).
        public static var midWordGhostRollingEnabled: Bool {
            // ON PAR DÉFAUT (endgame Phase A) : la fenêtre glissante + refill + ancre
            // bidirectionnelle. Tuée par le kill-switch MAÎTRE (cascade, pas de ghost à
            // rouler) OU par son propre `SOUFFLEUSE_ROLLING_OFF` (garder le longghost
            // statique sans roulement).
            let env = ProcessInfo.processInfo.environment
            return env["SOUFFLEUSE_LONGGHOST_OFF"] == nil && env["SOUFFLEUSE_ROLLING_OFF"] == nil
        }

        /// `MW_ROLL_DEPTH` — profondeur (mots entiers) qu'on essaie de garder
        /// affichée DEVANT le caret. Défaut 4. Clampé ≥ 1.
        public static var ghostRollingTargetWords: Int {
            if let s = ProcessInfo.processInfo.environment["MW_ROLL_DEPTH"], let v = Int(s) { return max(1, v) }
            return 4
        }

        /// `MW_ROLL_MIN` — on recharge dès que le reste affiché descend SOUS ce
        /// nombre de mots entiers. Défaut 2. Clampé ≥ 1.
        public static var ghostRollingMinWords: Int {
            if let s = ProcessInfo.processInfo.environment["MW_ROLL_MIN"], let v = Int(s) { return max(1, v) }
            return 2
        }

        // MARK: - LLM context window (coherence, 2026-05-29 measurement)
        ///
        /// Number of trailing characters of the (corrected) preceding text fed
        /// to the model as `beforeCursor`. Sized by a window A/B on the real
        /// engine (19 FR+EN coherence cases, windows 256→2048): **512 was the
        /// WORST window** — a 512-char cut can land mid-sentence and sever the
        /// discourse thread, producing generic filler instead of a
        /// context-anchored continuation (e.g. a far "remboursement"/"dashboard"
        /// antecedent is lost). The previous "more context dilutes a 1B model"
        /// rationale was UNSUPPORTED (0/14 within-512 controls changed across any
        /// window). 1024 never truncates mid-thought, matches/beats 512
        /// everywhere, and recovers far-antecedent coherence; cost ≈ +60ms warm
        /// prefill TTFT, paid once per cold field (KV reuse covers steady
        /// typing). 2048 added nothing for +185ms. NOTE: conjugation/agreement
        /// was already correct even at 256 (French cues sit near the caret) — the
        /// window fixes DISCOURSE coherence, not distance agreement.
        public static let llmContextWindowChars: Int = 1024

        /// **Ancrage de la fenêtre de contexte (12/06).** Sans ancre, la fenêtre
        /// `suffix(1024)` GLISSE d'un caractère à chaque frappe dès que le champ
        /// dépasse 1024 chars : la tête du `beforeCursor` change → le prefix-cache
        /// KV du beam est invalidé → chaque génération re-prefill ~300 tokens.
        /// Mesuré (run C, note > 1024 chars) : 49 repaints/142 frappes vs 150-161
        /// dans un champ court, seeds « partiels » 229 ms vs 47-90 chauds.
        /// Avec ancre : la tête reste FIXE tant que le contenu de la fenêtre tient
        /// sous `window + slack`, puis se ré-ancre d'un cran (~un re-prefill
        /// toutes les ~slack frappes au lieu d'un par frappe).
        /// Kill-switch `SOUFFLEUSE_WINDOW_ANCHOR_OFF` ⇒ retour au suffix glissant.
        public static var llmWindowAnchorEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_WINDOW_ANCHOR_OFF"] == nil
        }

        /// Marge d'ancrage : la fenêtre peut grossir jusqu'à `window + slack`
        /// chars avant ré-ancrage. 256 ≈ ~50 frappes entre deux re-prefills,
        /// pour +25 % de prompt au pire (1280 chars) — bien sous le palier 2048
        /// mesuré inutile (+185 ms).
        public static let llmContextWindowSlackChars: Int = 256

        /// **Debounce conditionnel (12/06).** Quand la réserve beam paraît chaude
        /// (la frappe prolonge `beamSessionTail` de ≤ 3 chars), le predict sera
        /// très probablement servi par l'avancée de réserve (HIT ~1 ms, aucun
        /// coût LLM) : les 15 ms de debounce AppDelegate ne protègent alors rien
        /// et retardent le ghost. **ON PAR DÉFAUT** (A/B 12/06 : tick→predict
        /// 40 → 21 ms p50 sur ~1/3 des frappes, mêmes suggestions nouvelles
        /// 44 vs 45 — le gain est la réactivité du ghost vivant, repaints
        /// 76 → 103, HITs 13 → 16 ; aucune tempête de predicts, annulées
        /// 66 → 62). Un faux positif coûte juste un predict avancé de 15 ms,
        /// absorbé par le cancel-on-keystroke. Kill-switch :
        /// `SOUFFLEUSE_DEBOUNCE_SKIP_WARM_OFF`.
        public static var debounceSkipWarmReserveEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_DEBOUNCE_SKIP_WARM_OFF"] == nil
        }

        // MARK: - D-08 Cache / undo-cache floors (tightening 2026-05-26)
        ///
        /// `cacheFloor` gates `cache.lookup(...)` hits. Before this tightening,
        /// any non-empty cache hit was displayed unconditionally — that's how
        /// stale LLM fragments from prior sessions kept polluting the ghost
        /// after the user typed an unrelated prefix. Now cache hits must score
        /// above `cacheFloor` (re-using `SuggestionPolicy.score(...)` with
        /// `source: .cache`) to be shown.
        public static let cacheFloor: Float = 0.55

        /// `undoCacheFloor` gates `cache.longestExtendingKey(...)` hits (undo
        /// as ghost — "user just backspaced, propose to restore"). Signal très
        /// fort (le suffixe a été LITTÉRALEMENT tapé) → barre basse. Abaissée
        /// 0.45 → 0.30 : un undo d'1 mot (« Monsieur ») scorait 0.39 (0.65×1×0.6)
        /// et était recalé. Env-réglable `MW_UNDO_FLOOR` pour l'A/B.
        public static var undoCacheFloor: Float {
            if let s = ProcessInfo.processInfo.environment["MW_UNDO_FLOOR"], let v = Float(s) { return v }
            return 0.30
        }

        // MARK: - D-09 Classification windows (assumptions A2-A4 in RESEARCH)
        public static let parasiteWindow: TimeInterval = 0.8
        public static let uselessMinVisibleMs: Int = 200
        public static let badMaxDivergeMs: Int = 500

        // MARK: - D-06 Source priors
        public static let sourcePrior: [SuggestionSource: Float] = [
            .wordComplete: 0.55,
            .learnedWord:  0.80,   // terme distinctif appris (gates freq/dominance déjà appliqués)
            .history:      0.75,
            .llm:          0.60,
            .cache:        0.70,
            .undoCache:    0.65,
            .none:         0.0,
        ]

        // MARK: - D-06 Bell curve length_fit (index = word count, clamp to last for >=10)
        public static let lengthFitByWordCount: [Float] = [
            0.0,  // 0 mots — défensif
            0.6,  // 1 mot
            1.0,  // 2
            1.0,  // 3
            1.0,  // 4
            1.0,  // 5
            0.85, // 6 — bord du sweet spot
            0.6,  // 7
            0.6,  // 8
            0.3,  // 9+ — trop long
        ]

        // MARK: - Garde-fou C (survie termes/chiffres dans la traduction)
        //
        // Mécanisme C (TRANSLATION-SPEC §2.8) : on extrait de la source FR les
        // tokens « durs » (montants/chiffres, %, termes métier, noms propres) et
        // on vérifie leur survie dans la traduction. Pitfall 6 : ces seuils
        // n'existent QUE ici.

        /// Termes métier crypto-fiscalité dont la disparition dans la traduction
        /// est un signal fort de dérive (le 1B-it les « adapte » parfois).
        /// Comparaison insensible à la casse. Liste courte et de haute précision :
        /// un terme listé doit presque toujours survivre tel quel d'une langue à
        /// l'autre.
        public static let termSurvivalBusinessTerms: [String] = [
            "wallet", "Binance", "Coinbase", "Kraken", "Ledger", "MetaMask",
            "staking", "NFT", "gas", "CSV", "PDF", "Stripe", "Bitcoin", "Ethereum",
            "BTC", "ETH", "USDC", "USDT", "DeFi", "airdrop", "KYC", "IBAN", "API",
            "Waltio", "blockchain", "token", "smart contract",
        ]

        /// Longueur canonique (chiffres seuls) minimale d'un nombre pour être
        /// surveillé. 2 → on ignore les chiffres isolés (« un 1er… ») tout en
        /// attrapant montants et pourcentages (la corruption observée au gate —
        /// « 1 250,50 € » → « 250,50 € » — fait 6 chiffres).
        public static let termSurvivalMinNumberDigits: Int = 2

        /// Longueur minimale d'un nom propre capitalisé surveillé (réduit le bruit
        /// sur les mots de 1-2 lettres en tête de phrase).
        public static let termSurvivalProperNounMinLength: Int = 3

        /// Nombre maximum de tokens manquants listés dans le badge HUD ; au-delà,
        /// on agrège en « +N ».
        public static let termSurvivalMaxBadgeItems: Int = 4

        // MARK: - Traduction : contexte, ordonnancement GPU, longueur de sortie
        //
        // TRANSLATION-SPEC §2.9. Single source of truth (les littéraux de
        // longueur/fenêtre de traduction vivent ICI, pas aux points d'appel).

        /// Fenêtre de contexte du moteur instruct (traduction). 2048 (vs 1024)
        /// laisse de quoi conserver INTÉGRALEMENT la consigne + un long message +
        /// sa traduction sans head-truncation (qui amputerait la consigne de
        /// fidélité, en tête de prompt). Coût mémoire KV modeste sur un 1B.
        public static let translationContextTokens: UInt32 = 2048

        /// Attente maximale (ms) que le ghost FR se taise avant de DÉMARRER une
        /// traduction. Bornée : au-delà on lance quand même (la traduction ne doit
        /// jamais être bloquée indéfiniment).
        public static let translationGhostWaitMaxMillis: Int = 400
        /// Pas de sondage de l'attente ci-dessus.
        public static let translationGhostWaitPollMillis: Int = 30

        /// Plancher / plafond du nombre de tokens générés pour une traduction.
        public static let translationMaxNewTokensFloor: Int = 160
        public static let translationMaxNewTokensCap: Int = 768

        /// Nombre de tokens de sortie ADAPTÉ à la longueur de la source : une
        /// traduction fait ~la longueur du message, donc plafonner à une constante
        /// trop basse tronque les longs messages (= traduction imparfaite). On
        /// estime ~0,4 token par caractère source + une marge, clampé. Pur,
        /// testable. NOTE (UAT 11/06) : les flux runtime (traduction, relecture,
        /// transformations) utilisent désormais `transformMaxNewTokens`, plus
        /// généreux — cette estimation ~0,4 tronquait les sorties qui s'allongent
        /// (relecture FR→FR, accents). Conservée comme référence/bench.
        public static func translationMaxNewTokens(sourceChars: Int) -> Int {
            let estimated = sourceChars * 2 / 5 + 48
            return min(translationMaxNewTokensCap, max(translationMaxNewTokensFloor, estimated))
        }

        /// Plancher / plafond du nombre de tokens générés pour une transformation « // ».
        public static let transformMaxNewTokensFloor: Int = 192
        public static let transformMaxNewTokensCap: Int = 768

        /// Budget de sortie d'une transformation « // » : contrairement à la
        /// traduction (sortie ≈ source en tokens), une correction/réécriture
        /// FR→FR peut s'ALLONGER (accents plus coûteux en tokens, consigne libre
        /// expansive) — le budget traduction tronquait en plein mot (UAT 11/06).
        /// ~0,6 token par caractère source + marge, clampé. Pur, testable.
        public static func transformMaxNewTokens(sourceChars: Int) -> Int {
            let estimated = sourceChars * 3 / 5 + 64
            return min(transformMaxNewTokensCap, max(transformMaxNewTokensFloor, estimated))
        }

        /// Délai d'inactivité (s) après lequel le moteur instruct (traduction) est
        /// déchargé pour rendre la RAM (Phase 7). Compromis : trop court = rechargement
        /// fréquent (~1-2 s) ; trop long = RAM tenue inutilement. 180 s = l'utilisateur
        /// a clairement quitté le flux de traduction.
        public static let translationIdleUnloadSeconds: Int = 180

        /// Délai d'inactivité (s) de FRAPPE après lequel le moteur ghost (GGUF)
        /// est déchargé pour rendre la RAM (~0,8 Go). Le déclencheur est l'arrêt
        /// de la frappe, pas la perte de focus — il survit donc aux pauses de
        /// réflexion en milieu de phrase, mais rend la RAM dès que l'utilisateur
        /// lit / designe / passe sur une app non-texte. Rechargé paresseusement
        /// (~1 s) dès qu'on recommence à composer. 60 s = pause franche.
        public static let ghostIdleUnloadSeconds: Int = 60
        // Le moteur ghost endormi est réveillé dès la 1ʳᵉ frappe dans un champ
        // texte (cf. `manageGhostWarmth`). Les zones de RECHERCHE sont exclues en
        // amont (`AXSnapshot.isSearchField`) → plus de seuil de chars à régler ici.

        /// Durée (s) d'affichage du panneau de traduction APRÈS la fin de la
        /// traduction, avant l'auto-masquage en fondu — assez longue pour lire et
        /// pour saisir/déplacer le panneau. Le survol souris suspend ce compte.
        public static let translationHUDVisibleSeconds: Double = 6

        // MARK: - Carnet d'usage (frappes épargnées / temps gagné)

        /// Cadence de frappe par défaut (ms/caractère) tant qu'on n'a pas assez
        /// d'échantillons pour calibrer sur l'utilisateur. ~180 ms/char ≈ 5,5 char/s
        /// ≈ 65 mots/min — un dactylo moyen. Volontairement conservateur.
        public static let ledgerDefaultMillisPerChar: Double = 180

        /// Nombre de caractères frappés à accumuler avant d'utiliser la cadence
        /// MESURÉE plutôt que le défaut — en-dessous l'estimation serait trop
        /// bruitée par la quantification du poll.
        public static let ledgerCadenceMinSampleChars: Int = 200

        /// Coût (s) d'ACCEPTER un ghost (lire + presser Tab), soustrait du temps
        /// gagné pour ne pas sur-vendre. Conservateur = crédible.
        public static let ledgerAcceptOverheadSeconds: Double = 0.4

        /// Au-delà de ce delta de caractères entre deux polls, on n'échantillonne
        /// PAS la cadence : c'est un collage ou une injection d'accept, pas de la
        /// frappe humaine (qui fait 1-4 char par tick de 80 ms).
        public static let ledgerCadenceMaxCharsPerSample: Int = 6

        /// Écart max (s) entre deux croissances de texte encore comptées comme de
        /// la frappe continue. Au-delà = pause / réflexion, on ne mesure pas.
        public static let ledgerCadenceMaxGapSeconds: Double = 2.0

        /// Nombre de jours d'historique conservés dans le carnet (sparkline).
        public static let ledgerHistoryDays: Int = 30

        /// Intervalle min (s) entre deux écritures disque du carnet, pour ne pas
        /// marteler le disque à chaque frappe mesurée. Les accepts/actes forcent
        /// une écriture immédiate (rares).
        public static let ledgerSaveThrottleSeconds: Double = 5

        // MARK: - Garde anti-écho du préambule de contexte (privacy + qualité)
        //
        // Le modèle PT base, quand il n'a (presque) rien à continuer — champ
        // vide typiquement — recrache le BLOC DE CONTEXTE injecté en tête de
        // prompt (« App Signal, window … », ou un bout de presse-papier / OCR)
        // au lieu de continuer l'utilisateur. C'est à la fois du méta-texte
        // générique ET une FUITE à l'écran du presse-papier / OCR. La garde
        // `OutputFilter.echoesContextPreamble` le supprime. Seuils ICI (Pitfall
        // 6). Calibrés sur les traces overlay réelles (2026-05-31) : les ~1153
        // échos affichés mesurés font 9–17 chars normalisés (« app signal
        // window »=17 ×911, « app signal »=10 ×232, « app brave »=9 ×8), donc
        // un simple plancher de longueur les raterait — la branche cadre
        // s'ancre sur l'EN-TÊTE réel du préambule, pas sur une longueur.

        /// Plancher (chars NORMALISÉS, cf. `normalizeForRepeatCheck`) de
        /// préfixe COMMUN entre le ghost et l'en-tête du préambule au-delà
        /// duquel le ghost est jugé « écho de cadre » (branche A). Auto-ancré
        /// sur le nom d'app / le label de champ live : une vraie continuation
        /// qui ne fait que partager un mot (« App Store est lent » → « app
        /// store… ») diverge de l'en-tête réel (« app signal… ») avant ce
        /// plancher et SURVIT. 8 ≈ « app » + le début d'un nom d'app court
        /// (« app brave »=9, « app mail »=8) ; assez bas pour attraper toute la
        /// distribution mesurée, assez haut pour ne jamais coller à du « app »
        /// générique. (Faux positifs mesurés : 0.)
        public static let contextEchoFrameHeadMinChars: Int = 8

        /// Sous ce nombre de chars (userTail trimmé) le champ est considéré
        /// VIDE : la branche B (dump presse-papier / OCR n'importe où dans le
        /// préambule) s'arme alors. 2 → une élision (« j' ») ou un mot d'une
        /// lettre (« Je ») commencé suffit à désarmer la branche B, donc dès que
        /// l'utilisateur tape du vrai texte une complétion qui réutilise un
        /// segment du contexte n'est jamais touchée.
        public static let contextEchoEmptyTailMaxChars: Int = 2

        /// Longueur minimale (chars normalisés) d'un run du préambule reproduit
        /// par le ghost dans un champ VIDE pour valoir un dump (branche B).
        /// Gardé HAUT (vs le plancher cadre) pour qu'un mot incident court
        /// présent dans un blob presse-papier de 200 chars ne tue pas un ghost
        /// légitime de champ vide. ~16 ≈ 3 mots verbatim — un vrai dump, pas une
        /// coïncidence.
        public static let contextEchoDumpMinChars: Int = 16

        // MARK: - Load governor (steadier under heavy load) — parité Cotypist
        //
        // Sous pression thermique/CPU, on coalesce les générations (debounce
        // allongé) et on coupe le refill spéculatif : moins de décodes llama
        // démarrés-puis-annulés = moins de churn GPU/CPU quand le Mac peine.
        // Le ghost *seed* n'est jamais dégradé (même contenu) — voir LoadGovernor.

        /// Master switch du gouverneur de charge. **ON par défaut** : devient
        /// `false` (comportement historique, aucun throttling adaptatif) UNIQUEMENT
        /// si l'env `SOUFFLEUSE_LOAD_GOVERNOR_OFF` est présente. À `.nominal` le
        /// gouverneur est de toute façon transparent (multiplicateur 1.0, aucun
        /// gate) ; le kill-switch sert l'A/B et la mesure de régression.
        public static var loadGovernorEnabled: Bool {
            ProcessInfo.processInfo.environment["SOUFFLEUSE_LOAD_GOVERNOR_OFF"] == nil
        }
    }
}
