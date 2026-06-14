import Foundation
import NaturalLanguage
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog
import SouffleusePersonalization
import SouffleusePrompt
import SouffleuseTyping

// MARK: - Value types (Phase 4 / 04-05 — extracted alongside PVM, no callers yet)


// `PredictRequest` — extracted VERBATIM to `SouffleuseCore.PredictRequest`
// (Phase 5). Re-exported here is unnecessary: ModelRuntime imports
// SouffleuseCore, so `PredictRequest` resolves unqualified at every call-site.

// MARK: - ModelRuntime

/// Model lifecycle owner — extraction step 1 of D-03 (Phase 4 wave 4).
/// Depuis le retrait du container MLX (11/06/2026, mesuré 870 MB / ~10 s de
/// chargement pour zéro consommateur), ne possède plus QUE les moteurs
/// llama.cpp (ghost + beam).
///
/// **Scope du plan 04-05** :
/// - Owns `modelId: String` + `lastError`.
/// - Implémente `loadModel()` et `swap(to:completionCache:)` — copies
///   verbatim des bodies PVM.
/// - Héberge les pure-function helpers (OutputFilter sub-namespace,
///   `buildSystemPrompt`, `detectLanguage`) qui seront partagés avec PVM
///   en 04-07.
/// - **PAS de `generate(...)`** : cette méthode (le body de
///   `container.perform`) est migrée en 04-06 derrière un env flag
///   `SOUFFLEUSE_USE_MODEL_RUNTIME`.
///
/// **Important** : en 04-05, **aucun caller ne référence ModelRuntime**.
/// PVM continue d'appeler ses propres `Self.stripPrefixOverlap`,
/// `Self.buildSystemPrompt`, son propre `loadModel()`. ModelRuntime existe
/// alongside sans consommateur, ce qui permet :
/// 1. Compile clean immédiatement (les types co-existent).
/// 2. Tests OutputFilter peuvent tourner sans rien casser dans PVM.
/// 3. Revert propre si 04-06 ou 04-07 échouent.
@MainActor
final class ModelRuntime {
    /// Identifiant HuggingFace du modèle MLX (ex. `mlx-community/gemma-3-1b-pt-4bit`).
    /// LEGACY : plus aucun poids MLX n'est chargé (le container a été retiré —
    /// 870 MB résidents pour zéro consommateur, bench TTFTBench 11/06/2026).
    /// Conservé comme clé de prefs/catalogue tant que l'UI legacy la référence.
    private(set) var modelId: String

    /// Dernière erreur de chargement, surfacée à l'UI via la façade PVM en 04-07.
    /// Forme `"load_failed: <localizedDescription>"`.
    private(set) var lastError: String?

    /// llama.cpp engine — the SOLE generation path (Metal GGUF). Tout le texte
    /// du ghost vient de `llamaEngine` ; le n-gram perso tokenise aussi en ids
    /// llama (`setCorpus`).
    let llamaEngine = LlamaEngine()

    /// Moteur **beam contraint** — le cœur LLM unifié sous `SOUFFLEUSE_BEAM_CORE`
    /// (K=3, `requiredPrefix` mid-mot). Chargé À CÔTÉ du `llamaEngine` (contexte
    /// dédié `n_seq_max = K+1`, cf. BeamGhostEngine §POURQUOI) UNIQUEMENT quand le
    /// flag est posé — sinon jamais touché, RAM intacte, chemin byte-identique.
    /// COÛT connu (spike) : un 2ᵉ chargement du même GGUF (poids ~1 Go dupliqués) ;
    /// acceptable derrière le flag, optimisable plus tard en partageant le model
    /// handle (un seul `llama_model`, deux contextes).
    let beamEngine = BeamGhostEngine(config: .ghostCore())

    /// Largeur K effective du beam (env-aware via `ghostCore()`), pour le mid-mot.
    private let beamWidth = BeamConfig.ghostCore().maxSearchWidth

    /// True once the GGUF is loaded into the beam engine (only attempted when
    /// `beamCoreEnabled`). Gates `generateGhostBeam`.
    private(set) var beamReady = false

    /// `userTail` au moment du dernier seed/advance de la session réserve
    /// (`SOUFFLEUSE_BEAM_RESERVE`). La CONTINUITÉ — le nouveau tail prolonge
    /// l'ancien de 1-3 chars — est l'UNIQUE critère de validité de la réserve :
    /// backspace, Tab accepté, changement de champ/app, repositionnement du
    /// caret cassent tous le préfixe → re-seed automatique. nil = pas de session.
    private var beamSessionTail: String?


    /// NSSpellChecker wrapper, reused for the mid-word coherence guard
    /// (`OutputFilter.midWordCandidate` + `isValidWord`). Process-wide and
    /// thread-safe behind its own `@unchecked Sendable` declaration, so it can
    /// be captured by the `@Sendable` onToken closure without crossing back to
    /// the actor on every token.

    /// True once the GGUF is loaded into the llama engine.
    private(set) var llamaReady = false

    /// Currently-selected GGUF model id (from `GGUFModelOption.catalogue`).
    /// Drives `resolveGGUFPath()` — the file the llama engine loads. Defaults
    /// to the fast 1B Q5 entry ; updated by `swapGGUF(to:)`.
    private(set) var ggufModelID: String = GGUFModelOption.defaultID

    /// True when the runtime can produce ghost text — i.e. the llama engine
    /// has a GGUF loaded.
    var canGenerate: Bool { llamaReady }

    init(initialModelId: String, ggufModelID: String = GGUFModelOption.defaultID) {
        self.modelId = initialModelId
        self.ggufModelID = ggufModelID
    }

    /// Resolves the local GGUF path used by the llama engine, derived from the
    /// currently-selected `ggufModelID`. Overridable globally via
    /// `SOUFFLEUSE_GGUF` (debug). Falls back to the default 1B Q5 entry when the
    /// selected entry's file can't be found. No network : the file must already
    /// exist locally.
    func resolveGGUFPath() -> String {
        let option = GGUFModelOption.option(forID: ggufModelID)
        if let path = option.resolvePath() {
            return path
        }
        // Selected entry unresolved → fall back to the default 1B entry so the
        // ghost still works ; the UI flags the missing file separately.
        if let fallback = GGUFModelOption.option(forID: GGUFModelOption.defaultID).resolvePath() {
            return fallback
        }
        // Last-resort literal (mirrors the historical hardcoded path).
        return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
            .expandingTildeInPath
    }

    // MARK: Lifecycle

    /// Charge le(s) moteur(s) llama.cpp (ghost + beam optionnel).
    ///
    /// L'événement `model_load_failed` reste byte-identique au legacy
    /// (StaticString, count nil) pour preserver la signature audit.sh.
    func loadModel() async {
        // Primary generation engine : llama.cpp + local GGUF (Metal).
        let ggufPath = resolveGGUFPath()
        let ok = await llamaEngine.load(modelPath: ggufPath, contextTokens: 4096)
        llamaReady = ok
        if !ok {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: gguf"
            return
        }

        // Beam core (flag `SOUFFLEUSE_BEAM_CORE`) : crée le contexte multi-séquences
        // du beam sur le MÊME `llama_model` que le ghost greedy (poids EMPRUNTÉS via
        // `borrowModel()` — pas de 2ᵉ Go en RAM). Hors flag, jamais chargé.
        if SuggestionPolicy.Tuning.beamCoreEnabled {
            if let borrowed = await llamaEngine.borrowModel() {
                beamReady = await beamEngine.load(borrowedModel: borrowed, contextTokens: 4096)
            } else {
                beamReady = false
            }
            if !beamReady { Log.error(.predictor, "model_load_failed") }
        }
        // NOTE 11/06/2026 : le chargement « best-effort » du container MLX qui
        // vivait ici a été RETIRÉ. Il matérialisait ~870 MB de poids Metal et
        // ~10 s de churn à chaque réveil pour un objet que plus rien ne lisait
        // (le n-gram perso tokenise en ids llama via `LlamaEngine.setCorpus`).
        // Mesure : SouffleuseTTFTBench, phases A/B/C.
        self.lastError = nil
    }

    /// Swap vers un nouveau modelId (legacy MLX catalogue). Idempotent si
    /// `id == modelId`. Le GGUF llama est indépendant de cet id (cf.
    /// `swapGGUF(to:)` pour le vrai moteur) — on invalide les caches et on
    /// recharge llama (idempotent sur un chemin déjà chargé).
    ///
    /// **NOTE** : la cancellation de la generate en cours est l'affaire du
    /// caller (PVM/GenerationPlanner) AVANT d'appeler `runtime.swap(...)`.
    /// ModelRuntime n'a pas accès au planner — cf. comment Task 2 du plan.
    func swap(to id: String, completionCache: CompletionCache) async {
        guard id != modelId else { return }
        modelId = id
        completionCache.invalidateAll()
        await loadModel()
    }

    /// Swaps the active **GGUF** model (the real ghost engine). Reloads ONLY
    /// the llama engine on the newly-resolved path — the MLX container is NOT
    /// touched (it is decoupled from the user's choice now). `LlamaEngine.load`
    /// tears down the prior model and resets KV state (kvTokens=[]). Idempotent
    /// when `id == ggufModelID`.
    ///
    /// Returns true when the new GGUF loaded successfully. The caller is
    /// responsible for re-feeding the personalization corpus afterwards
    /// (token-id n-gram + suffix array must be rebuilt for the reloaded engine).
    /// Sets the GGUF selection before the first `loadModel()`. No reload — the
    /// next `loadModel()` will resolve and load this entry's path.
    func configureInitialGGUF(_ id: String) {
        guard !llamaReady else { return }
        ggufModelID = id
    }

    @discardableResult
    func swapGGUF(to id: String) async -> Bool {
        guard id != ggufModelID else { return llamaReady }
        ggufModelID = id
        let ggufPath = resolveGGUFPath()
        // ORDRE CRITIQUE : le beam emprunte le `llama_model` de `LlamaEngine`. Le
        // reload ci-dessous va libérer l'ANCIEN modèle ; on décharge donc d'abord
        // le contexte du beam (sinon il référencerait un modèle libéré), puis on
        // le recrée sur le NOUVEAU modèle emprunté après le reload.
        if beamReady {
            await beamEngine.unload()
            beamReady = false
        }
        let ok = await llamaEngine.load(modelPath: ggufPath, contextTokens: 4096)
        llamaReady = ok
        if !ok {
            Log.error(.predictor, "model_load_failed")
            self.lastError = "load_failed: gguf"
        } else {
            self.lastError = nil
        }
        // Recrée le contexte beam sur le nouveau modèle emprunté (flag uniquement).
        if SuggestionPolicy.Tuning.beamCoreEnabled, ok {
            if let borrowed = await llamaEngine.borrowModel() {
                beamReady = await beamEngine.load(borrowedModel: borrowed, contextTokens: 4096)
            }
        }
        return ok
    }

    /// Feeds the personalization corpus (accepted-text strings) into the
    /// llama engine, which rebuilds its llama-token-id n-gram. Called at
    /// startup once the GGUF is loaded and after each acceptance / clear.
    /// Cheap full rebuild — the corpus is small (ring buffer ≤ 200 entries).
    /// Le beam est nourri AUSSI (mêmes entrées, mêmes ids — modèle partagé)
    /// pour le bias de l'expansion (flag SOUFFLEUSE_BEAM_BIAS). Guard
    /// beamCoreEnabled : flag core OFF ⇒ le beam n'est jamais touché (l'appel
    /// serait un no-op — setCorpus clear+guard handles — mais on préserve
    /// l'invariant « beam intact » à la lettre).
    func setCorpus(_ entries: [String]) async {
        await llamaEngine.setCorpus(entries)
        if SuggestionPolicy.Tuning.beamCoreEnabled {
            await beamEngine.setCorpus(entries)
        }
    }

    /// Heuristique SYNCHRONE (zéro hop d'actor) : vraie quand la frappe courante
    /// a toutes les chances d'être servie par l'avancée de réserve (HIT/REFILL,
    /// ~1 ms, aucun coût LLM). Miroir des gardes de continuité du bloc réserve
    /// de `generateGhostBeam` — SANS le `beamEngine.hasReserve` (async) : un
    /// faux positif coûte seulement un debounce sauté pour un predict qui
    /// seedera, inoffensif. Sert au debounce conditionnel
    /// (`debounceSkipWarmReserveEnabled`).
    func reserveLooksWarm(userTail: String) -> Bool {
        guard SuggestionPolicy.Tuning.beamReserveEnabled, beamReady,
              let prev = beamSessionTail, !prev.isEmpty,
              userTail.count > prev.count,
              userTail.count - prev.count <= 3,
              userTail.hasPrefix(prev) else { return false }
        return true
    }

    /// Décharge le moteur ghost (GGUF llama.cpp) pour rendre la RAM quand
    /// l'utilisateur ne compose pas. Après ça `canGenerate` est faux →
    /// `predict()` baille proprement sur son gate. Un `loadModel()` ultérieur
    /// recharge réellement (`LlamaEngine.unload()` a libéré le model +
    /// context). L'appelant DOIT avoir annulé la génération en cours avant
    /// (cf. `cancel()` côté PVM/AppDelegate) ; l'acteur `LlamaEngine` sérialise
    /// de toute façon `unload` après tout `generate` en vol.
    func unloadGhost() async {
        // ORDRE CRITIQUE : le beam emprunte le modèle de `LlamaEngine`. On libère
        // d'abord le contexte du beam, PUIS le modèle (via llamaEngine.unload) —
        // sinon le contexte beam pointerait un modèle déjà libéré.
        await beamEngine.unload()
        beamReady = false
        await llamaEngine.unload()
        llamaReady = false
    }

    // MARK: - OutputFilter / prompt helpers (extracted to SouffleuseCore)

    /// `OutputFilter` was moved VERBATIM to `SouffleuseCore.OutputFilter`
    /// (Phase 5). This typealias keeps every `ModelRuntime.OutputFilter.*`
    /// call-site (PVM, AppDelegate, tests) compiling unchanged.
    typealias OutputFilter = SouffleuseCore.OutputFilter

    /// Mid-word confidence gate threshold — forwarding shim to
    /// `LlamaPromptBuilder.midWordMinFirstTokenProb` (extracted Phase 5).
    static var midWordMinFirstTokenProb: Float { LlamaPromptBuilder.midWordMinFirstTokenProb }

    /// Forwarding shim — see `LlamaPromptBuilder.autocompleteSystemPrompt`.
    static var autocompleteSystemPrompt: String { LlamaPromptBuilder.autocompleteSystemPrompt }

    /// Forwarding shim — see `LlamaPromptBuilder.buildSystemPrompt`.
    static func buildSystemPrompt(detectedLanguage: String?) -> String {
        LlamaPromptBuilder.buildSystemPrompt(detectedLanguage: detectedLanguage)
    }

    /// Forwarding shim — see `LlamaPromptBuilder.detectLanguage`.
    static func detectLanguage(in text: String) -> String? {
        LlamaPromptBuilder.detectLanguage(in: text)
    }

    // MARK: - generate (04-06 — verbatim port of PVM container.perform body)


    /// Résultat d'une escalade mid-mot (Frame C). `show` ⇒ le caller affiche
    /// `word` (le mot greedy/modal, déterministe) ; sinon il cache (retombe sur le
    /// ghost instant). `word` + `reason` exposés même caché pour l'inspecteur DEV.
    struct MidWordEscalationResult: Sendable {
        let show: Bool
        let word: String
        let reason: String     // "fast-accept" / "fast-reject" / "branch agree=0.75"
        /// Niveau d'engagement quand le gradient `MW_ENGAGEMENT` est actif (sinon
        /// `.plein` par défaut — comportement long-ghost statique inchangé, le
        /// rolling reste autorisé comme aujourd'hui hors flag).
        let engagement: SuggestionPolicy.MidWordEngagement
        /// Le rolling refill est-il autorisé pour ce souffle ? Hors gradient =
        /// toujours `true` (byte-identique). Sous gradient = vrai en PLEIN seulement.
        var rollingAllowed: Bool { engagement.rollingAllowed }

        init(show: Bool, word: String, reason: String,
             engagement: SuggestionPolicy.MidWordEngagement = .plein) {
            self.show = show
            self.word = word
            self.reason = reason
            self.engagement = engagement
        }
    }

    /// **Cœur LLM beam (flag `SOUFFLEUSE_BEAM_CORE`).** Génère le ghost via le
    /// `BeamGhostEngine` contraint — le SEUL chemin LLM sous le flag, en
    /// remplacement du greedy long-ghost / engagement / plancher dico.
    ///
    /// - **Mid-mot** (`partial` non vide, même si le fragment est un mot valide
    ///   du dico) → beam avec `requiredPrefix = partial`, largeur K=3. La
    ///   contrainte force à ne pas abandonner le mot tapé (elle n'empêche pas de
    ///   le terminer) ; le ranking log-prob tranche l'accord (handoff §a/§b :
    ///   intention 64 % vs 29 %, accord 9/10 vs 4/10 ; PARITY-FINDINGS.md :
    ///   céder la contrainte aux fragments « mots valides » coûtait 55 → 0 % de
    ///   mots justes à 1 lettre).
    /// - **Vrai après-espace** (`partial` vide) → décode LIBRE à K=1 (≡ greedy,
    ///   §4A : le beam n'aide pas après-espace et K>1 y perd en cohérence). Le
    ///   `routeInstant` reste DEVANT pour le rappel.
    ///
    /// Post-filtré par `beamPostFilter` (singleLine, dédup, séparateur, écho
    /// positionnel, word-cap) puis par les deux gardes de phrase. Réutilise
    /// `MidWordEscalationResult` pour un call-site PVM commun (show/word/reason).
    ///
    /// **Génération fraîche glissante** (décision UX) : chaque frappe (débouncée)
    /// régénère une fenêtre de `maxWords` mots DEPUIS tout le texte tapé — pas de
    /// réserve pré-calculée. La fenêtre glisse en avant et reste TOUJOURS
    /// conditionnée sur ce que l'utilisateur a réellement tapé. (Le reuse
    /// HIT/REFILL/MISS de la réserve n'amortissait quasi pas en frappe libre — 13 %
    /// de HIT — et n'allongeait pas le ghost ni ne re-conditionnait sur le tapé ;
    /// abandonné ici, le code moteur reste dormant sous le flag.)
    ///
    /// Deux gardes de PHRASE :
    ///  • **G1 (fin de phrase)** : si le ghost contient un `.` `!` `?`, on NE
    ///    propose RIEN — on ne met pas la fin de phrase dans la bouche de
    ///    l'utilisateur (géré dans `beamPostFilter`).
    ///  • **G2 (reprise après le point)** : tant que la PHRASE EN COURS (texte
    ///    après le dernier `.!?`) a moins de `beamMinSentenceLetters` lettres, on
    ///    se tait. Juste après un point ⇒ silence ; on reprend dès que l'utilisateur
    ///    a amorcé la nouvelle phrase (le modèle a alors un vrai contexte).
    func generateGhostBeam(request: PredictRequest) async -> MidWordEscalationResult? {
        guard beamReady else { return nil }
        let userTail = request.userTail

        // ── Bias corpus (préférence « Teinter les suggestions », ou flag dev
        // SOUFFLEUSE_BEAM_BIAS — OU logique, défaut OFF) ─────────────────────
        // Même calibration de gain que la voie greedy : slider Préférences
        // (0…2, via request.personalizationStrength) × gain scale interne.
        // Posé en ÉTAT actor avant toute génération : le seed, la réserve
        // (re-beam MISS interne d'`advance`) et le refill en héritent. OFF ou
        // perso à 0 ⇒ gain 0 ⇒ expansion byte-identique.
        let biasOn = request.personalizedSuggestions || SuggestionPolicy.Tuning.beamBiasEnabled
        let beamBias: Float = biasOn
            ? Float(request.personalizationStrength) * LlamaSampling.personalizationGainScale
            : 0
        await beamEngine.setBiasStrength(beamBias)

        // G2 — reprise après le point : pas de proposition tant que la phrase en
        // cours n'est pas amorcée (≥ beamMinSentenceLetters lettres après le dernier
        // terminateur). Couvre « on reprend quand l'utilisateur a retapé quelques
        // lettres après le point » SANS coût LLM.
        guard BeamGhostShaper.sentenceArmed(userTail: userTail) else {
            // Silence G2 : la session réserve de la phrase précédente est morte
            // (le ghost repartira d'un seed frais à la reprise).
            beamSessionTail = nil
            return MidWordEscalationResult(show: false, word: "", reason: "beam-newsentence")
        }

        // Choix de config beam (mid-mot → requiredPrefix + K plein ; frontière →
        // décode libre K=1). Logique de mise en forme PURE → `BeamGhostShaper`.
        let choice = BeamGhostShaper.beamConfigChoice(userTail: userTail, beamWidth: beamWidth)
        let requiredPrefix = choice.requiredPrefix
        let isBoundary = choice.isBoundary
        let width = choice.width

        // Pref « Long » (request.maxWords ≥ trigger) : le beam génère jusqu'au cap
        // haut (`longGhostMaxWords` validé par SouffleuseMaxWordsEval) puis le
        // post-filtre rogne la queue pendante (`trimDanglingTail`). Court/Moyen :
        // `genTokens/genWords = nil` ⇒ config par défaut, comportement byte-identique.
        let isLong = request.maxWords >= BeamGhostShaper.longGhostTriggerWords
        let genTokens: Int? = isLong ? BeamGhostShaper.longGhostMaxTokens : nil
        let genWords: Int? = isLong ? BeamGhostShaper.longGhostMaxWords : nil

        // Prompt = contexte PROSE (« Contexte: » persona + ctxPrefix app/fenêtre/OCR,
        // prose que le base/PT CONTINUE bien) + tout le texte avant curseur. EXCLUS :
        // exemples few-shot (pollueur prouvé), annotation `Champ:`, FIM. Slots choisis
        // par `BeamGhostShaper.promptSlots` (mise en forme partagée avec la probe).
        let prompt = BeamGhostShaper.buildPrompt(
            customInstr: request.customInstr, ctxPrefix: request.ctxPrefix, llmTail: request.llmTail)

        // ── Réserve (flag SOUFFLEUSE_BEAM_RESERVE) : HIT/REFILL/MISS ─────────
        // Si le nouveau tail PROLONGE l'ancien de 1-3 chars et qu'une réserve
        // vit, on AVANCE char par char dans les branches pré-décodées : frappe
        // qui suit le ghost = HIT, 0 décode, ~0 ms. Divergence = MISS, re-beam
        // (avec capture d'une réserve fraîche) DANS `advance`. Toute rupture de
        // continuité (backspace, accept, changement de champ, llmTail ≠ userTail
        // après heal) tombe dans le seed frais ci-dessous.
        let reserveOn = SuggestionPolicy.Tuning.beamReserveEnabled
        if reserveOn,
           let prev = beamSessionTail,
           request.llmTail == userTail,           // pas de correction typo en vol
           userTail.count > prev.count,
           userTail.count - prev.count <= 3,      // debounce : au plus quelques chars
           userTail.hasPrefix(prev),
           await beamEngine.hasReserve {
            var advanced: AdvanceResult?
            var tail = prev
            GpuGate.shared.ghostBegan()
            for ch in userTail.dropFirst(prev.count) {
                tail.append(ch)
                let c = BeamGhostShaper.beamConfigChoice(userTail: tail, beamWidth: beamWidth)
                advanced = await beamEngine.advance(typedChar: ch,
                                                    requiredPrefixForMiss: c.requiredPrefix,
                                                    missWidth: c.width)
                if Task.isCancelled { break }
            }
            GpuGate.shared.ghostEnded()
            if Task.isCancelled { return nil }
            beamSessionTail = userTail
            if let a = advanced {
                Log.info(.predictor, "ghost_beam_advance_ms", count: a.elapsedMillis)
                // Trace de latence : chemin servi (1 hit / 2 refill / 3 miss).
                switch a.kind {
                case .hit: LatencyTrace.mark("gen_path", key: LatencyTrace.key(request.prefix), info: 1)
                case .refill: LatencyTrace.mark("gen_path", key: LatencyTrace.key(request.prefix), info: 2)
                case .miss: LatencyTrace.mark("gen_path", key: LatencyTrace.key(request.prefix), info: 3)
                }
                let caretAfterSpace = request.llmTail.last == " " || request.llmTail.last == "\t"
                // Coupe anti-recopie mid-line : la réserve ne livre qu'UNE branche
                // (pas d'alternatives à itérer) — si elle recopie le texte après
                // caret, on la coupe/abstient ; le prochain seed re-proposera.
                let ghost = BeamGhostShaper.afterCaretEchoCut(
                    ghost: BeamGhostShaper.beamPostFilter(
                        rawGhost: a.ghost, isBoundary: isBoundary, caretAfterSpace: caretAfterSpace,
                        userTail: userTail, maxWords: request.maxWords, trimDanglingTail: isLong),
                    afterCaret: request.axTextAfterCaret)
                let reason: String
                switch a.kind {
                case .hit: reason = "beam-hit"
                case .refill: reason = "beam-refill"
                case .miss: reason = "beam-miss"
                }
                return MidWordEscalationResult(show: !ghost.isEmpty, word: ghost,
                                               reason: ghost.isEmpty ? "beam-gated" : reason)
            }
            // advanced nil (dropFirst vide — ne devrait pas arriver) → seed frais.
        }

        // GPU gate (parité translation, TRANSLATION-SPEC §2.9) autour du beam.
        GpuGate.shared.ghostBegan()
        let result: BeamResult
        if reserveOn {
            // Seed de session : beam + CAPTURE de la réserve pour les frappes
            // suivantes. La rupture de continuité a déjà invalidé l'ancienne
            // réserve (les seqs sont recyclées par `generateBeam`).
            result = await beamEngine.ghostWithReserve(prompt: prompt,
                                                       requiredPrefix: requiredPrefix,
                                                       maxWidth: width,
                                                       genMaxTokens: genTokens, genMaxWords: genWords)
            beamSessionTail = userTail
        } else {
            result = await beamEngine.ghost(prompt: prompt, requiredPrefix: requiredPrefix, maxWidth: width,
                                            genMaxTokens: genTokens, genMaxWords: genWords)
        }
        GpuGate.shared.ghostEnded()
        if Task.isCancelled { return nil }
        Log.info(.predictor, "ghost_beam_seed_ms", count: result.elapsedMillis)
        // Trace de latence : seed (4 avec capture de réserve / 5 sans), taille du
        // prompt en tokens et part RÉUTILISÉE du prefix-cache — c'est la mesure
        // qui départage « la queue lourde = re-prefill post-wipe » (LCP ≈ 0 sur
        // gros prompt) d'une autre cause.
        LatencyTrace.mark("gen_path", key: LatencyTrace.key(request.prefix), info: reserveOn ? 4 : 5)
        LatencyTrace.mark("seed_prompt", key: LatencyTrace.key(request.prefix), info: result.promptTokenCount)
        LatencyTrace.mark("seed_lcp", key: LatencyTrace.key(request.prefix), info: result.reusedPrefixTokens)
        // Décomposition interne du seed : prefill vs boucle de décodage — c'est
        // elle qui dira si le seed lent paie le contexte (decode qui grandit avec
        // le KV) ou la prefill (cache froid).
        LatencyTrace.mark("seed_prefill_ms", key: LatencyTrace.key(request.prefix), info: result.prefillMillis)
        LatencyTrace.mark("seed_decode_ms", key: LatencyTrace.key(request.prefix), info: result.decodeMillis)

        let caretAfterSpace = request.llmTail.last == " " || request.llmTail.last == "\t"
        // Mid-line (texte non-blanc sur la ligne après le caret) : `selectGhost`
        // itère les K candidats et prend le premier qui ne RECOPIE pas ce qui est
        // déjà tapé après le curseur. Hors mid-line, il post-filtre le best seul —
        // byte-identique à l'historique.
        let rawCandidates = result.candidates.isEmpty
            ? [result.best?.ghost ?? ""]
            : result.candidates.map(\.ghost)
        let ghost = BeamGhostShaper.selectGhost(
            rawCandidates: rawCandidates, isBoundary: isBoundary, caretAfterSpace: caretAfterSpace,
            userTail: userTail, maxWords: request.maxWords, afterCaret: request.axTextAfterCaret,
            trimDanglingTail: isLong)
        Log.info(.predictor, "ghost_beam_words",
                 count: ghost.split(whereSeparator: { $0.isWhitespace }).count)
        return MidWordEscalationResult(show: !ghost.isEmpty, word: ghost,
                                       reason: ghost.isEmpty ? "beam-gated" : "beam")
    }

    // La logique de mise en forme PURE du cœur beam (seuil de phrase G2,
    // `currentSentenceLetterCount`, choix requiredPrefix/largeur, slots de prompt,
    // post-filtre de sortie) vit désormais dans `BeamGhostShaper` (SouffleuseCore),
    // pour être IMPORTABLE par la probe `SouffleuseBeamGhostProbe` (le target
    // exécutable `Souffleuse` ne l'est pas). `generateGhostBeam` ci-dessus appelle
    // directement le shaper — comportement byte-identique (extrait verbatim).





    /// **Rolling-refill : prolonge le ghost affiché** (mode sliding-window,
    /// parité Cotypist). Continue depuis une frontière PROPRE — la fin du texte
    /// visible = ce que l'utilisateur a tapé/validé PLUS le reste encore non
    /// consommé (`beforeCursor` est déjà le texte complet visible). Donc PAS de
    /// `healPrefix` ici (on n'est pas mid-mot, on enchaîne après le reste).
    ///
    /// UNE passe greedy, post-traitée par les MÊMES helpers que `midWordLongGhost`
    /// (singleLine, coupe à la 1ʳᵉ frontière de clause, cap à `maxWords` mots
    /// entiers, espace de tête préservé pour se concaténer proprement sur le
    /// reste). Renvoie `nil`/vide si rien d'exploitable.
    /// Variante BEAM du refill glissant (sous `SOUFFLEUSE_BEAM_CORE`) : régénère la
    /// continuation DEPUIS le texte visible courant (`committed + remainder`, porté
    /// par `request.llmTail`) — donc conditionnée sur TOUT ce qui est tapé/affiché,
    /// pas un top-up greedy stale. Décode libre K=1 (continuation après une
    /// frontière propre = la fin du reste), post-filtré comme le ghost beam (G1
    /// coupe-clause inclusive → ne dépasse pas la fin de phrase ; espace de tête
    /// pour la concaténation). C'est ce refill qui MAINTIENT le living ghost vivant
    /// pendant la consommation (sinon la fenêtre fond à zéro → « pas live »).
    /// Renvoie le texte à APPENDRE au reste, ou nil si rien d'exploitable.
    func extendGhostBeam(request: PredictRequest, maxWords: Int, isLong: Bool = false) async -> String? {
        guard beamReady else { return nil }
        // NB réserve (SOUFFLEUSE_BEAM_RESERVE) : ce refill passe par `generateBeam`
        // qui recycle les seqs de branches → la réserve est droppée à chaque
        // rallonge. C'est VOULU : pendant la consommation live, `predict()` ne
        // tourne pas (l'AppDelegate slice le reste et appelle CE refill) — la
        // réserve ne peut donc pas maintenir la fenêtre ; la neutraliser ici
        // vidait le living ghost (régression constatée au clavier). La réserve
        // ne sert que le chemin predict (divergences courtes).
        let prompt = BeamGhostShaper.buildPrompt(
            customInstr: request.customInstr, ctxPrefix: request.ctxPrefix, llmTail: request.llmTail)
        // Même gain de bias que le seed (préférence ou flag dev) : la rallonge
        // du living ghost doit voir le même corpus que la génération initiale.
        let biasOn = request.personalizedSuggestions || SuggestionPolicy.Tuning.beamBiasEnabled
        let beamBias: Float = biasOn
            ? Float(request.personalizationStrength) * LlamaSampling.personalizationGainScale
            : 0
        await beamEngine.setBiasStrength(beamBias)
        // En Long, la rallonge doit générer autant de mots que la fenêtre en réclame
        // (`maxWords` = wantWords), pas le cap court par défaut (3) — sinon le living
        // ghost retombe à ~3 mots pendant la conso. nil en Court/Moyen ⇒ inchangé.
        let genW: Int? = isLong ? max(1, maxWords) : nil
        let genT: Int? = isLong ? (max(1, maxWords) * 4 + 2) : nil
        GpuGate.shared.ghostBegan()
        let result = await beamEngine.ghost(prompt: prompt, requiredPrefix: "", maxWidth: 1,
                                            genMaxTokens: genT, genMaxWords: genW)
        GpuGate.shared.ghostEnded()
        if Task.isCancelled { return nil }
        // Trace de latence : prompt/LCP du refill — symétrique des marques seed,
        // pour mesurer la guerre de prefix-cache entre les deux chemins.
        LatencyTrace.mark("refill_prompt", key: LatencyTrace.key(request.prefix), info: result.promptTokenCount)
        LatencyTrace.mark("refill_lcp", key: LatencyTrace.key(request.prefix), info: result.reusedPrefixTokens)
        LatencyTrace.mark("refill_prefill_ms", key: LatencyTrace.key(request.prefix), info: result.prefillMillis)
        LatencyTrace.mark("refill_decode_ms", key: LatencyTrace.key(request.prefix), info: result.decodeMillis)
        var ext = BeamGhostShaper.beamPostFilter(
            rawGhost: result.best?.ghost ?? "", isBoundary: true, caretAfterSpace: false,
            userTail: request.userTail, maxWords: maxWords, trimDanglingTail: isLong)
        // Mid-line : un refill qui recopie le texte après le caret réintroduirait
        // la duplication que `selectGhost` vient d'éviter au seed — même coupe.
        // `axTextAfterCaret` est nil sur le chemin end-of-line → no-op.
        ext = BeamGhostShaper.afterCaretEchoCut(ghost: ext, afterCaret: request.axTextAfterCaret)
        guard !ext.isEmpty else { return nil }
        if ext.first != " " { ext = " " + ext }   // espace de tête pour se concaténer au reste
        Log.info(.predictor, "ghost_beam_refill_ms", count: result.elapsedMillis)
        return ext
    }


    /// Une passe d'escalade (greedy ou branche) : génère, renvoie le mot de tête +
    /// la confiance top-1 si demandée. Pas de `GpuGate` ici — le bracketing est
    /// fait UNE fois par `midWordEscalate`. `temperature 0` = greedy déterministe ;
    /// `> 0` = branche stochastique seedée (`topP 0.9`).
    private func runEscalationPass(
        prompt: String, partial: String, cap: Int,
        temperature: Float, seed: UInt32, captureP1: Bool
    ) async -> (lead: String, p1: Double?, fullLine: String) {
        final class Acc: @unchecked Sendable { var text = "" }
        let acc = Acc()
        let metrics = await llamaEngine.generate(
            prompt: prompt,
            maxTokens: cap,
            sampling: LlamaSampling(
                temperature: temperature,
                repeatPenalty: 1.3,
                repeatLastN: 64,
                seed: seed,
                personalizationStrength: 0,
                topP: temperature > 0 ? 0.9 : 0,
                banMarkup: true,
                banDigitsLeading: true,
                banEmoji: true,
                minFirstTokenProb: captureP1 ? Float(SuggestionPolicy.Tuning.escFirstTokenProbEpsilon) : 0,
                healPrefix: partial.isEmpty ? nil : partial
            )
        ) { piece in
            if Task.isCancelled { return false }
            acc.text += piece
            return true
        }
        let oneLine = acc.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? acc.text
        // `lead` = mot de tête dé-fragmenté (gardien du vote, inchangé) ; `fullLine`
        // = le texte greedy complet d'une ligne (C1 : sert la CONTINUATION mot+suite
        // quand le mot est confirmé). Les branches ne lisent que `lead` pour voter.
        return (SuggestionPolicy.midWordLeadWordDefrag(oneLine, partial: partial),
                metrics.firstTokenProb, oneLine)
    }


    /// Assembles the prompt for **raw text continuation**.
    ///
    /// The shipped GGUF is the **base / pretrained** Gemma 3 (`finetune = pt`),
    /// NOT the instruct model — same file Cotypist uses. A base model has never
    /// seen the `<start_of_turn>` chat template or instruction framing; wrapping
    /// it in one produces generic/off-topic words and English drift. So we feed
    /// it the way a base model expects: plain text it simply continues, ending
    /// in `beforeCursor`. Cotypist does the same (its `basePromptPrefix` + raw
    /// text). Any contextual prose (app/field context) is prepended as a light
    /// prefix; `beforeCursor` is always last so the continuation extends it.
    ///
    /// `system` / `afterCursor` are intentionally NOT injected as instructions —
    /// a base model can't follow imperative directives and they only pollute the
    /// continuation. Language steering is unnecessary: the base model continues
    /// in whatever language the input text is already in.
    ///
    /// `customInstr` (the user's personalisation) IS injected — but as a French
    /// `Contexte :` PROSE block, never as a command. A base/PT model can't obey
    /// "your name is X", yet it readily CONTINUES from a stated fact: prepending
    /// "Contexte : Je m'appelle Gabriel." makes "Je m'appelle " complete to
    /// "Gabriel" instead of a random name. Proven at the probe (VOLET PERSONA):
    /// every framing fixed the name; the French `Contexte :` label specifically
    /// did so WITHOUT bleeding the persona into unrelated text (an English "My
    /// writing:" label dragged "Cocotypist" into a delivery sentence — avoided).
    /// This mirrors Cotypist, which injects the same kind of labelled block
    /// (`PromptTemplates` / "My writing:") rather than a chat-template system
    /// message.
    ///
    /// **Phase 5** : forwarding shim to `LlamaPromptBuilder.buildLlamaPrompt`
    /// (extracted to SouffleuseCore). Kept so `ModelRuntime.buildLlamaPrompt`
    /// call-sites (generateLlama, BuildLlamaPromptTests) compile unchanged.
    static func buildLlamaPrompt(
        system: String,
        customInstr: String,
        ctxPrefix: String,
        fieldContext: String,
        afterCursor: String,
        beforeCursor: String,
        examples: String = ""
    ) -> String {
        LlamaPromptBuilder.buildLlamaPrompt(
            system: system,
            customInstr: customInstr,
            ctxPrefix: ctxPrefix,
            fieldContext: fieldContext,
            afterCursor: afterCursor,
            beforeCursor: beforeCursor,
            examples: examples
        )
    }
}
