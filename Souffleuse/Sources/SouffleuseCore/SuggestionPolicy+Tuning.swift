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
        public static let examplesInjectionEnabled: Bool = true

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
        /// L1/L2 cascade decide. ~12 chars ≈ a short opener phrase — long
        /// enough to signal a clearly re-entered context while still recalling
        /// after-space openers like "Bonjour, " (~9 chars). Lowered from 16
        /// to 12 to reactivate recall of short sentence starters, matching
        /// Cotypist behaviour on greetings and salutations.
        public static let strongCorpusMatchMinChars: Int = 12

        /// `MW_STRONG_MINCHARS` — seuil after-space du strong-corpus, override live
        /// (A/B sans rebuild, même pattern que `afterSpaceL1BarRuntime` /
        /// `escBranchKRuntime`). Env absente ⇒ la constante (12). Clampé ≥ 1 pour
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

        /// `SOUFFLEUSE_GHOST_STREAM` — peint le longghost AU FIL des tokens (TTFT ~20 ms)
        /// au lieu d'attendre la génération complète (~300 ms, que la frappe suivante
        /// annulerait). OFF par défaut ⇒ one-shot d'origine, byte-identique.
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
        /// testable.
        public static func translationMaxNewTokens(sourceChars: Int) -> Int {
            let estimated = sourceChars * 2 / 5 + 48
            return min(translationMaxNewTokensCap, max(translationMaxNewTokensFloor, estimated))
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
    }
}
