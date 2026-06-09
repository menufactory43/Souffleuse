import Foundation
import SouffleuseAX
import SouffleuseCore
import SouffleuseLog
import SouffleuseCorpus
import SouffleusePersonalization
import SouffleusePrompt
import SouffleuseTyping

/// Opt-in debug trace for predict() decisions. Gated on env var
/// `SOUFFLEUSE_PREDICT_LOG` (any non-empty value enables). Writes raw user
/// text to `/tmp/souffleuse-predict.log` — NEVER use in production builds
/// or check audit.sh's privacy rules; /tmp is acceptable for active debug.
/// Launch with: `SOUFFLEUSE_PREDICT_LOG=1 open .../Souffleuse.app`
private enum PredictDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["SOUFFLEUSE_PREDICT_LOG"]?.isEmpty == false
    static let path = "/tmp/souffleuse-predict.log"
    static let lock = NSLock()

    static func log(_ tag: String, _ payload: String = "") {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(tag) \(payload)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

/// Mutable @MainActor-only flag recording whether the in-flight generation has
/// ever set a ghost for the current prefix (a valid LLM chunk, or an empty-chunk
/// fallback to a valid instant ghost). Captured by both the `onChunk` closure
/// and the completion block — both run on @MainActor, so a plain reference box
/// is race-free. Drives the stale-ghost clear in `predict(...)`.
@MainActor
private final class GhostEmissionTracker {
    var emitted = false
}

/// Phase 4 D-03 (plan 04-07) — Final façade form of the predictor view model.
///
/// PVM is now a thin observable surface over `ModelRuntime` (which owns the
/// llama.cpp generation engine + the MLX tokenizer container) and the four
/// extracted modules : `SuggestionPolicyEngine`, `GenerationPlanner`,
/// `CompletionCache`. The cascade (L0 word completion + L1 history exact-
/// substring + L2 LLM stream) lives directly in `predict(...)` below.
///
/// Pre-04-07 the model dispatched between a pre-split body and the cascade
/// wiring via an env-flag (see 04-06 SUMMARY for the historical dispatcher
/// shape). Per the 04-07-EMPIRICAL-VALIDATION verdict (PASS, runtime path
/// subjectively equivalent to legacy), the flag and the legacy body have
/// been removed. `predict(...)` IS the cascade wiring.
@MainActor
@Observable
final class PredictorViewModel {
    enum LoadState: Equatable {
        case idle
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    var loadState: LoadState = .idle
    var suggestion: String = ""
    /// The exact `prefix` (text before the caret) that the current `suggestion`
    /// was generated for. The render boundary MUST refuse to paint `suggestion`
    /// unless this equals the live prefix — otherwise a ghost produced for an
    /// earlier keystroke (kept alive in `suggestion` through one of the many
    /// gating paths while a fresh stream is pending) gets painted at the new
    /// caret. That is the "Bonjour" repro: a stale start-of-message ghost shown
    /// far downstream at "…autre chose pou". Empty until the first suggestion is
    /// produced; reset on `cancel()` and on the stale-clear path.
    private(set) var predictedForPrefix: String = ""

    /// Gradient d'engagement (flag `MW_ENGAGEMENT`) : le ghost courant autorise-t-il
    /// le ROLLING REFILL (living ghost) ? Vrai en niveau PLEIN, faux en PRUDENT
    /// (1 mot figé). HORS flag, toujours `true` ⇒ le rolling roule comme aujourd'hui
    /// (le long-ghost statique reste roulant). Lu par `SouffleuseAppDelegate`
    /// (`maybeSpawnRollingRefill`) pour gater le refill par-décision.
    /// `@MainActor`-only (PVM l'est) ; `@ObservationIgnored` car un changement ne
    /// doit pas, à lui seul, redessiner — il accompagne `suggestion` qui, lui, le fait.
    @ObservationIgnored
    private(set) var ghostRollingAllowed: Bool = true
    var ttftMillis: Int?
    var tokensPerSecond: Double?
    var lastError: String?

    /// Provenance of the current `suggestion`. Drives the anti-churn rule in
    /// the LLM `onChunk` path: high-confidence sources (history, cache hit)
    /// are protected from being REPLACED by a different-direction LLM
    /// stream — the LLM may only EXTEND them. Low-confidence sources
    /// (word completion, none) can be freely replaced when the LLM
    /// produces a strictly longer output.
    ///
    /// Phase 4 D-03 : le type `SuggestionSource` est désormais défini au
    /// top-level dans `SuggestionPolicy.swift`. Les références internes
    /// continuent de résoudre via global lookup.
    private(set) var suggestionSource: SuggestionSource = .none

    /// Phase 4 D-03 (plan 04-05/06/07) : tout le runtime MLX (container,
    /// modelId, loadModel, swap, generate) vit dans `ModelRuntime`. PVM
    /// délègue son lifecycle modèle exclusivement à ce sous-système.
    @ObservationIgnored
    private let runtime: ModelRuntime

    /// Phase 4 — lifecycle (generation counter + currentTask + debounce)
    /// extrait dans `GenerationPlanner`. PVM délègue : `planner.beginGeneration()`
    /// remplace `generation &+= 1` + `currentTask?.cancel()` ; les closures
    /// onChunk capturent un `GenerationToken` (value-type Sendable) et
    /// utilisent `planner.isCurrent(token)` au lieu de `self.generation == myGeneration`.
    /// Pitfall 1 du RESEARCH §"Common Pitfalls" — Token comparé par valeur,
    /// pas de risque de capture stale d'une référence.
    private let planner = GenerationPlanner()

    /// Phase 4 D-03 (plan 04-04) : tous les caches cross-keystroke (predict
    /// memo FIFO, tokenCountCache, KVCacheHolder, lastContextFingerprint) sont
    /// consolidés dans `CompletionCache`. PVM délègue via `cache.lookup` /
    /// `cache.store` / `cache.kvCacheHolder` / `cache.decideExtendTrimInvalidate`.
    /// Le `KVCacheBypassFlag` vit désormais dans `CompletionCache.swift` —
    /// l'env var de bypass D-KV-06 y est byte-identique (single source of truth).
    internal let cache = CompletionCache()

    private var modelId: String
    /// Last language `detectLanguage` resolved *with confidence* (English name,
    /// e.g. "French"). Short or low-confidence prefixes make `detectLanguage`
    /// return nil mid-typing — exactly the autocomplete case — which would drop
    /// the language-steering header and let the 1B model drift to English. We
    /// keep the last confident detection and reuse it when the current prefix is
    /// undetectable; a *new* confident detection always wins and overwrites it.
    private var lastDetectedLanguage: String?
    /// Driven by Preferences > Général > "Longueur des suggestions".
    /// Combined with sentence-end truncation in onChunk for snappy output.
    var maxTokens: Int = 10
    /// Hard cap on whole words shown to the user, mirroring CompletionLength.maxWords.
    /// Phase 4 : sync'd into `policy.updateMaxWords(...)` via `didSet` so the
    /// SuggestionPolicyEngine's routeInstant cap matches the LLM stream cap.
    var maxWords: Int = 6 {
        didSet { policy.updateMaxWords(maxWords) }
    }
    /// Personalization knob. 0 disables the personalization bias entirely (fast
    /// path, existing behaviour). When > 0, the llama engine sharpens its logits
    /// from the accepted-text corpus n-gram (`runtime.setCorpus`).
    var personalizationStrength: Float = 0
    /// When true, completed-word typos in the prefix are corrected *only in the
    /// model input* (Volet 1). The user's displayed text and `userTail`
    /// (anti-repeat / cache key) are never altered. Default on; mirrored from
    /// `PreferencesStore.prefixCorrectionEnabled` by the AppDelegate.
    var prefixCorrectionEnabled: Bool = true
    /// Silent prefix typo corrector (pure wrapper over NSSpellChecker). Only
    /// rewrites the `llmTail` fed into the llama prompt's `beforeCursor`.
    private let prefixCorrector = PrefixCorrector()
    /// Historique chiffré on-device. Source du corpus de personnalisation (via
    /// `rebuildPersonalization` / `ingestAccepted`, alimenté dans le n-gram
    /// llama par `runtime.setCorpus`). Wiré depuis `SouffleuseAppDelegate` au
    /// démarrage. Quand nil, la personnalisation reste inactive (cas tests /
    /// startup).
    ///
    /// Note (2026-05-26): le retrieval few-shot a été dropé (cf. drop fewshot
    /// commit) — la personnalisation passe désormais exclusivement par le logit
    /// bias n-gram côté llama.cpp.
    var history: TypingHistoryStore?
    /// System-API word completion. Runs synchronously on the main actor so
    /// the ghost can show up before the LLM has even started — matches the
    /// instant-feedback feel of Cotypist on partial words.
    private let wordCompleter = WordCompleter()

    /// Détecteur de mots valides (NSSpellChecker) — sert la garde d'admission
    /// partagée `TypingHistoryStore.admissionRejection` côté ingestion mémoire,
    /// pour que la mémoire applique EXACTEMENT les mêmes 4 gardes que le disque.
    private let typoDetector = TypoDetector()

    /// Plafond de caractères du `userTail` (la queue de texte visible nourrie au
    /// modèle). Au-delà, le préfixe est tronqué — le contexte lointain n'aide pas
    /// la complétion locale et coûte des tokens. Constante unique partagée par
    /// `predict()` et `extendGhost()` (avant : literal `2048` dupliqué aux deux).
    static let userTailCap = 2048

    /// Phase 4 — Ghost Relevance Gate engine. Owns currentGhost/currentSource/
    /// currentScore/shownAt + the 5 classification events. PVM delegates cascade
    /// routing (L0/L1) and LLM chunk replacement-bar to this engine ; partial-
    /// accept + typedDiverged hooks will land in 04-04+ when TypingSession
    /// is extracted (D-03).
    private let policy = SuggestionPolicyEngine(maxWords: 6)

    /// Synchronous snapshot of typing history for Instant Ghost Path Layer 1.
    /// `TypingHistoryStore` is an actor (async); the predict() hot path runs
    /// on the main actor and needs immediate access. We mirror the actor's
    /// state into this main-actor-owned array, refreshed on rebuild + on
    /// every new acceptance. Capped at 200 entries × ~80 chars context =
    /// ~16KB peak, well within budget for a linear scan in <1ms.
    private(set) var historySnapshot: [TypingHistoryEntry] = []

    /// Personal lexicon of the user's DISTINCTIVE terms (proper nouns / brands /
    /// jargon) for instant L0 word-completion the LLM can't do ("Bin"→"Binance").
    /// Derived from `historySnapshot`; rebuilt in lockstep with it (rebuild + on
    /// every accept) so it always reflects the same corpus. Queried by
    /// `routeInstant`. `@ObservationIgnored` — a lexicon refresh must not redraw
    /// any view.
    @ObservationIgnored private var learnedLexicon = LearnedLexicon()

    /// Registre (DomainCluster) de l'app focus au dernier `predict()`. Mémorisé
    /// pour que `extendGhost` (refill glissant, sans `axSnapshot`) scope son
    /// few-shot sur le même cluster — la continuation reste dans le bon registre
    /// (P1.3). `.other` ⇒ aucun scope (comportement historique).
    @ObservationIgnored private var lastActiveDomain: DomainCluster = .other

    /// Active GGUF model id (the real ghost engine). Mirrored from
    /// `PreferencesStore.ggufModelID` at startup ; changed via `swapGGUF(to:)`.
    private var ggufModelID: String = GGUFModelOption.defaultID

    init(ggufModelID: String = GGUFModelOption.defaultID) {
        let initialModelId = "mlx-community/gemma-3-1b-pt-4bit"
        self.modelId = initialModelId
        self.ggufModelID = ggufModelID
        self.runtime = ModelRuntime(initialModelId: initialModelId, ggufModelID: ggufModelID)
    }

    /// Swaps the active **GGUF (llama.cpp)** model — the model that actually
    /// produces the ghost. Cancels any in-flight generation, reloads the llama
    /// engine on the new GGUF (which resets KV state), then re-feeds the
    /// personalization corpus so the token-id n-gram + suffix array are rebuilt
    /// for the reloaded engine. Surfaces `loadState = .loading` during the load
    /// (the 4B model is ~2.5 GB, noticeably slower than the 1B). No-op when the
    /// id already matches. Does NOT touch the legacy MLX container.
    /// Sets the GGUF selection BEFORE the initial `loadModel()` so the engine
    /// loads the persisted model from disk on launch (no reload). Must be called
    /// before `loadModel()`. A no-op once a model is loaded — use `swapGGUF`.
    func configureInitialGGUF(_ id: String) {
        ggufModelID = id
        runtime.configureInitialGGUF(id)
    }

    func swapGGUF(to id: String) async {
        guard id != ggufModelID else { return }
        cancel(reason: .modelSwap)
        ggufModelID = id
        loadState = .loading(progress: 0)
        cache.invalidateAll()
        let ok = await runtime.swapGGUF(to: id)
        if !ok {
            let err = runtime.lastError ?? "load_failed: gguf"
            loadState = .failed(err)
            lastError = err
            return
        }
        // Re-feed the corpus : the reloaded engine has fresh (empty) n-gram /
        // suffix-array state, so rebuild it from the current history snapshot.
        let corpus = historySnapshot.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)
        loadState = .ready
    }

    /// Swap the active model. Cancels in-flight generation, drops the container,
    /// and triggers a fresh load with the new ID. Called when the user picks a
    /// different model in Preferences. No-op if `id` matches the active one.
    func swapModel(to id: String) async {
        guard id != modelId else { return }
        // Phase 4 — classification grid : model swap ends any visible ghost
        // lifecycle silently (D-09 — silent category). cancel(reason:) appelle
        // policy.endLifecycle(.modelSwap) en interne.
        cancel(reason: .modelSwap)
        modelId = id
        loadState = .idle
        // ModelRuntime.swap drops its container, updates its modelId, invalidates
        // the shared CompletionCache (predictCache + KV holder + tokenCountCache),
        // and reloads. The kv_cache_invalidate count:3 event is emitted by
        // `cache.invalidateAll()` inside runtime.swap.
        await runtime.swap(to: id, completionCache: cache)
        loadState = runtime.lastError.map(LoadState.failed) ?? .ready
        if let err = runtime.lastError { lastError = err }
    }

    /// Phase 4 D-03 shim — AppDelegate (toggle off, focus → different bundle)
    /// déclare un context break en appelant directement `clearPredictCache()`.
    /// La sémantique est : drop le predictCache memo ; le KV holder et le
    /// tokenCountCache sont préservés (ils dépendent du model et du tokenizer,
    /// pas du contexte UI).
    func clearPredictCache() {
        cache.clearPredictCache()
    }

    func loadModel() async {
        guard case .idle = loadState else { return }
        loadState = .loading(progress: 0)
        // ModelRuntime.loadModel owns container + lastError. We surface its
        // outcome through the PVM LoadState observable. Progress reporting is
        // currently swallowed inside ModelRuntime (per 04-05 doc-comment) ;
        // when reintroduced it will be a closure injected here.
        await runtime.loadModel()
        if let err = runtime.lastError {
            loadState = .failed(err)
            lastError = err
        } else {
            loadState = .ready
        }
    }

    /// Vrai quand le moteur ghost est résident et prêt à générer. L'AppDelegate
    /// s'en sert pour décider de réveiller le modèle quand l'utilisateur se met
    /// à composer (cf. lifecycle warmth).
    var isModelReady: Bool { runtime.canGenerate }

    /// Recharge le moteur ghost pour la voix COURANTE quand son GGUF vient
    /// d'arriver sur disque (fin de téléchargement à l'onboarding). Au lancement,
    /// si le fichier manquait, `loadModel()` a échoué → `loadState == .failed`,
    /// que le guard `.idle` de `loadModel()` ne franchit plus : il faut d'abord
    /// `unloadModel()` (remet `.idle`) puis recharger. No-op si le moteur génère
    /// déjà (modèle présent dès le départ, ex. dossier Cotypist legacy) → pas de
    /// reload destructeur du KV-cache chaud.
    func reloadAfterDownload() async {
        guard !runtime.canGenerate else { return }
        await unloadModel()
        await loadModel()
    }

    /// Décharge le moteur ghost pour rendre la RAM quand l'utilisateur ne
    /// compose pas. Annule la génération en vol, libère le GGUF + le container
    /// MLX, invalide le cache (le KV est parti avec le model) et REMET
    /// `loadState` à `.idle` — sans ça le guard `.idle` de `loadModel()`
    /// bloquerait le rechargement ultérieur.
    func unloadModel() async {
        cancel()
        await runtime.unloadGhost()
        cache.invalidateAll()
        loadState = .idle
    }

    /// Predict — Final façade form (04-07).
    ///
    /// Cascade :
    /// 1. Source decay (HIGH → .llm so a fresh layer can reclaim).
    /// 2. Routing instant (L0 word completion / L1 history exact-substring)
    ///    via `policy.routeInstant`. Narrow stability gate guards against
    ///    spell-checker flip-flop.
    /// 3. Cache lookup + undo-as-ghost short-circuit.
    /// 4. Field-hint gate when `userTail` is empty without AX hints.
    /// 5. Build slot bodies (system prompt, customInstr, ctxPrefix,
    ///    fieldContext, afterCursor) and assemble a `PredictRequest`.
    /// 6. Detached Task : await previous generation, precompute n-gram
    ///    snapshot + few-shot block off the main actor, call
    ///    `runtime.generate(...)`, mirror filtered chunks into observables
    ///    through the @MainActor onChunk closure.
    func predict(
        prefix: String,
        contextPrefix: String = "",
        customInstructions: String = "",
        axSnapshot: AXSnapshot? = nil
    ) {
        let userTail = String(prefix.suffix(Self.userTailCap))
        // The exact prefix this invocation produces a suggestion for. Stamped
        // onto `predictedForPrefix` at every site that assigns `suggestion`, so
        // the render boundary can prove freshness. Matches the AppDelegate's
        // `prefix` (text before caret) verbatim — same value flows in here.
        let forPrefix = prefix
        // Context-aware invalidation: predictCache is keyed on userTail
        // only, so a hit returns the same suggestion regardless of which
        // app/field the user is currently in. fieldContext + afterCursor
        // slots depend on axSnapshot — typing the same userTail in two
        // different apps now produces two different prompts but the cache
        // would still return the first one. We invalidate whenever the
        // slow-changing AX fingerprint (bundle/role/subrole/placeholder/
        // help) shifts. textAfterCaret and windowTitle are intentionally
        // NOT in the fingerprint: textAfterCaret moves with the caret
        // (every keystroke would invalidate), and windowTitle changes too
        // often to be useful.
        let contextFingerprint: String = [
            axSnapshot?.bundleID ?? "",
            axSnapshot?.role ?? "",
            axSnapshot?.subrole ?? "",
            axSnapshot?.placeholder ?? "",
            axSnapshot?.help ?? "",
        ].joined(separator: "|")
        cache.updateContextFingerprint(contextFingerprint)
        PredictDebug.log("predict_called", "userTail=\(userTail.debugDescription)")

        // Cluster de registre de l'app focus (P1.2). Résolu UNE fois ici et
        // partagé par le recall L1 (routeInstant) et le few-shot L2
        // (proseExamplesPool) pour scoper la personnalisation sur un corpus
        // homogène. `.other` (inconnu/nil) ⇒ AUCUN scope (comportement
        // historique) ; un cluster connu n'autorise que la prose des apps du
        // même registre — le privé (.chat) ne fuit jamais ailleurs.
        let activeDomain = DomainCluster.cluster(for: axSnapshot?.bundleID)
        lastActiveDomain = activeDomain   // mémorisé pour le scope du refill (extendGhost, P1.3)

        // Source decay : a HIGH-confidence source set by a PREVIOUS predict
        // no longer reflects reality. Demote stale HIGH sources to .llm so
        // this predict can either re-confirm them via a fresh layer hit
        // (snapping back to HIGH) or accept legitimate updates from Layer 0
        // / LLM stream without being locked out.
        policy.beginPredict()
        suggestionSource = policy.currentSource == .none ? suggestionSource : policy.currentSource
        switch suggestionSource {
        case .history, .cache, .undoCache:
            suggestionSource = .llm
        case .wordComplete, .learnedWord, .llm, .none:
            break
        }
        let maxWords = self.maxWords

        // Instant Ghost Path Layers 0 + 1 — delegated to SuggestionPolicy.
        // routeInstant emits ghost_history_match / ghost_word_complete in
        // its internals ; applies D-08 matrix (mid-word = L0 only ;
        // after-space = L1 first behind afterSpaceL1Bar 0.4 ; else nil).
        let routeResult = policy.routeInstant(
            userTail: userTail,
            historySnapshot: historySnapshot,
            wordCompleter: wordCompleter,
            lexicon: learnedLexicon,
            activeDomain: activeDomain
        )
        // `singleLine` here is the single chokepoint for the instant path:
        // corpus / `.history` entries captured from prose can carry a trailing
        // "\n" (e.g. "achète du Bitcoin.\n"). Sanitising at the source means
        // every downstream use — the stability comparison below, the displayed
        // `suggestion`, and the drop-guard fallback in the LLM stream — sees a
        // clean single line, so the ghost never floats above the caret and a
        // Tab-accept never injects a line break.
        // Anti-répétition : un recall corpus qui redonne le mot déjà tapé
        // (« …bonjour » → « bonjour, comment… ») est rogné ICI, à la source, donc
        // tous les usages en aval (gate de stabilité ci-dessous, `suggestion`
        // affichée, fallback du stream LLM, décision stale-clear) voient le même
        // ghost dédupliqué. Un recall qui n'est QUE la répétition s'effondre à ""
        // et le garde `!instantGhost.isEmpty` le saute (le LLM reprend la main).
        let instantGhost: String = SuggestionPolicy.dedupLeadingRepeat(
            ghost: ModelRuntime.OutputFilter.singleLine(routeResult?.text ?? ""),
            userTail: userTail)
        let instantSource: SuggestionSource = routeResult?.source ?? .none
        if !instantGhost.isEmpty, let route = routeResult {
            // Narrow stability gate : only block when this predict and the
            // previous one BOTH produced a Layer 0 word completion AND the
            // new one doesn't extend the old (the spell-checker-changes-
            // its-mind case that produces visible flip-flop). Other
            // transitions replace freely.
            let bothLayer0 = suggestionSource == .wordComplete && instantSource == .wordComplete
            let extendsCurrent = instantGhost.count > suggestion.count
                && instantGhost.lowercased().hasPrefix(suggestion.lowercased())
            if !bothLayer0 || extendsCurrent {
                // `instantGhost` (dédupliqué + singleLine) plutôt que `route.text`
                // brut, pour que l'état policy (`currentGhost`, base du calcul de
                // remplacement par `onLLMChunk`) corresponde à ce qui est affiché.
                policy.applyGhost(instantGhost, source: route.source, score: route.score, userTail: userTail)
                suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(instantGhost)
                suggestionSource = instantSource
                // Rends le chemin INSTANTANÉ (L0 lexique / L1 corpus) visible dans
                // l'inspecteur — il n'enregistrait jusqu'ici que le chemin LLM. La
                // source est mise en `reason` (« instant:learnedWord » pour un
                // terme appris) pour distinguer lexique vs corpus vs dico.
                GhostInspector.shared.record(
                    tail: userTail, verdict: .shown, source: route.source,
                    reason: "instant", content: instantGhost, score: route.score)
            } else {
                Log.info(.predictor, "ghost_keep_stable", count: suggestion.count)
                PredictDebug.log("ghost_keep_stable", "current=\(suggestion.debugDescription) candidate=\(instantGhost.debugDescription)")
            }
            // Either we applied the instant ghost, or we kept the existing one
            // because the fresh L0 candidate didn't extend it — in both cases a
            // valid ghost for THIS prefix is on screen, so it is fresh.
            predictedForPrefix = forPrefix
        }

        // ── Frame C (F1) : escalade mid-mot ─────────────────────────────────
        // On emprunte l'escalade UNIQUEMENT quand : le caret est mid-mot sur un
        // fragment INCOMPLET (le cas qui fait aujourd'hui `midword_block` = rien)
        // ET L1 corpus n'a rien rappelé (`instantGhost` vide → l'escalade ne
        // pré-empte JAMAIS un rappel appris). Hors flag, toujours `false` → le
        // chemin streaming reste byte-identique.
        let useMidWordEscalation: Bool = {
            guard SuggestionPolicy.Tuning.midWordEscalationEnabled,
                  instantGhost.isEmpty,
                  let last = userTail.last, last.isLetter || last.isNumber else { return false }
            let partial = ModelRuntime.OutputFilter.trailingPartialWord(userTail)
            let complete = partial.count >= SuggestionPolicy.Tuning.midWordLLMMinCompleteWordChars
                && SuggestionPolicy.defaultPartialWordIsComplete(userTail)
            return !complete
        }()

        // ── Long-ghost AFTER-SPACE / next-word (unified path, flag-gated) ───
        // Quand `midWordLongGhostEnabled` est ON, on route AUSSI la génération
        // après-espace / mot-suivant par la MÊME passe greedy long-ghost que le
        // mid-mot, pour que le ghost soit produit uniformément et que le rolling
        // refill s'applique partout (parité Cotypist : un seul chemin de
        // génération, rolling continu). Conditions :
        //   • flag ON (sinon byte-identique à aujourd'hui : ancien cascade) ;
        //   • le caret est à une FRONTIÈRE de mot — `userTail` vide ou finissant
        //     par un blanc/ponctuation (PAS mid-mot incomplet, déjà couvert par
        //     `useMidWordEscalation`) ;
        //   • `instantGhost` VIDE — un rappel corpus (L1) reste prioritaire et
        //     instantané : on NE le clobber JAMAIS avec le LLM (le recall corpus
        //     est haute-confiance ; seul un champ sans recall passe au long-ghost).
        // `useMidWordEscalation` exclut déjà le mid-mot incomplet (dernier char
        // lettre/chiffre + partiel incomplet) ; ici on prend le COMPLÉMENT à la
        // frontière, donc les deux ne se chevauchent pas.
        let useAfterSpaceLongGhost: Bool = {
            guard SuggestionPolicy.Tuning.midWordLongGhostEnabled,
                  instantGhost.isEmpty else { return false }
            // Frontière de mot : tail vide, ou dernier char non lettre/chiffre
            // (espace, ponctuation, apostrophe…). Un dernier char alphanumérique
            // est traité comme frontière SI le mot courant est un mot complet du
            // dictionnaire (« C'est une| » → « une » est complet → next-word) ;
            // s'il est INCOMPLET (fragment « un| »), c'est du mid-mot → laissé à
            // `useMidWordEscalation`. `defaultPartialWordIsComplete` renvoie déjà
            // `false` pour un fragment incomplet, donc les deux gates restent
            // mutuellement exclusifs sans double génération.
            guard let last = userTail.last else { return true }
            if last.isLetter || last.isNumber {
                return SuggestionPolicy.defaultPartialWordIsComplete(userTail)
            }
            return true
        }()

        // ── Cœur LLM beam (flag SOUFFLEUSE_BEAM_CORE) ───────────────────────
        // Le beam contraint (K=3, requiredPrefix) remplace le greedy long-ghost /
        // l'escalade / le streaming comme SEUL chemin LLM. Calculé ici sur le
        // MainActor pour lire `runtime.beamReady` : faux si le flag est absent OU
        // si le beam n'a pas chargé → fallback SÛR vers le chemin actuel (jamais
        // de ghost muet sur un échec de chargement). `routeInstant` (L0/L1) reste
        // DEVANT et prioritaire — le beam ne tire que quand l'instant est vide.
        let useBeamCore = SuggestionPolicy.Tuning.beamCoreEnabled && runtime.beamReady

        // LLM gate : need at least 3 chars of trimmed userTail AND a
        // loaded runtime container.
        guard userTail.trimmingCharacters(in: .whitespaces).count >= 3,
              runtime.canGenerate else {
            return
        }

        // Cache hit : greedy decoding makes the same userTail produce the
        // same ghost. Restore the stabilised LLM suggestion instantly and
        // skip the 200ms-1s regen cycle.
        //
        // Tightening pass 2026-05-26 (post 04-07 empirical validation): cache
        // hits must now pass a Relevance Gate score check before being shown.
        // Before this, any non-empty cache entry was displayed unconditionally
        // — that's how stale LLM fragments from a prior context kept polluting
        // the ghost ("Je reviens " → "Je suis…" from earlier session). Cache
        // is high-prior (0.70) so a well-formed continuation easily clears
        // `cacheFloor=0.55` ; the gate only blocks malformed or off-shape
        // cached results.
        if let cached = cache.lookup(userTail: userTail) {
            if !cached.isEmpty {
                let capped = ModelRuntime.OutputFilter.capToWords(cached, max: maxWords)
                let score = SuggestionPolicy.score(source: .cache, ghost: capped, userTail: userTail)
                if score.value >= SuggestionPolicy.Tuning.cacheFloor {
                    suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(
                        ModelRuntime.OutputFilter.singleLine(capped))
                    predictedForPrefix = forPrefix
                    suggestionSource = .cache
                    planner.cancel()
                    Log.info(.predictor, "cache_hit", count: Int(score.value * 100))
                    PredictDebug.log("cache_hit", "cached=\(cached.debugDescription) score=\(score.value)")
                    return
                } else {
                    // Cache hit but score under floor — log and fall through
                    // to L1/L2 (do not cancel planner, do not overwrite ghost).
                    Log.info(.predictor, "cache_gate_block", count: Int(score.value * 100))
                    PredictDebug.log("cache_gate_block", "cached=\(cached.debugDescription) score=\(score.value)")
                }
            } else {
                // Empty cache entry — known-sterile prefix. Skip but do not
                // cancel planner (let the cascade continue).
                Log.info(.predictor, "cache_hit", count: 0)
                PredictDebug.log("cache_hit", "cached=empty")
                return
            }
        }

        // Undo-as-ghost : when the user backspaces over chars they had
        // already typed, propose to restore the deleted suffix as the
        // ghost. Find the longest cache key starting with userTail ; the
        // delta is the deleted suffix, delta + cachedSuggestion is the
        // proposed ghost. The user can Tab to instantly un-do their
        // deletion.
        //
        // Tightening 2026-05-26: same Gate treatment as cache hits, with a
        // slightly lower bar (`undoCacheFloor=0.45`) since the semantic
        // signal is strong (the suffix was literally typed before backspace).
        if let (key, cached) = cache.longestExtendingKey(userTail: userTail) {
            let delta = String(key.dropFirst(userTail.count))
            if !delta.isEmpty {
                let capped = ModelRuntime.OutputFilter.capToWords(delta + cached, max: maxWords)
                let score = SuggestionPolicy.score(source: .undoCache, ghost: capped, userTail: userTail)
                if score.value >= SuggestionPolicy.Tuning.undoCacheFloor {
                    planner.cancel()
                    suggestion = ModelRuntime.OutputFilter.singleLine(capped)
                    predictedForPrefix = forPrefix
                    suggestionSource = .undoCache
                    Log.info(.predictor, "cache_undo_hit", count: Int(score.value * 100))
                    PredictDebug.log("cache_undo_hit", "key=\(key.debugDescription) delta=\(delta.debugDescription) cached=\(cached.debugDescription) shown=\(suggestion.debugDescription) score=\(score.value)")
                    return
                } else {
                    Log.info(.predictor, "cache_undo_gate_block", count: Int(score.value * 100))
                    PredictDebug.log("cache_undo_gate_block", "key=\(key.debugDescription) score=\(score.value)")
                }
            }
        }

        // Field-hint gate : only block when userTail is truly empty AND
        // we have no AX field metadata to fall back on. With a placeholder/
        // role hint, the model has enough to propose something specific
        // (a subject line, a search query, a code stub) rather than fortune
        // cookies.
        let hasFieldHint = (axSnapshot?.placeholder?.isEmpty == false)
            || (axSnapshot?.help?.isEmpty == false)
            || (axSnapshot?.role != nil)
        if userTail.isEmpty && !hasFieldHint {
            PredictDebug.log("gate_empty_no_context", "")
            return
        }

        // Build the system prompt + slot bodies. Language steering : detect
        // the prefix's language and prepend an explicit "you must reply in
        // {language}" header. Counters the English-drift bias on
        // multilingual models.
        // Sticky language: a confident detection updates the remembered value;
        // an undetectable (short / low-confidence) prefix falls back to it so
        // the steering header survives mid-typing instead of vanishing.
        if let confident = ModelRuntime.detectLanguage(in: userTail) {
            lastDetectedLanguage = confident
        }
        let detectedLanguage = lastDetectedLanguage
        // ── Volet 1 : silent prefix correction (model input only) ──────────
        // Correct completed-word typos in the MODEL's view of the prefix so the
        // ghost continues from clean text. `userTail` (display / anti-repeat /
        // cache key) is intentionally NOT touched — only `correctedTail` flows
        // into the llama prompt's `beforeCursor`. Captured here on @MainActor
        // (PrefixCorrector is main-actor state); the detached Task receives the
        // already-corrected value as a plain Sendable string.
        let correctedTail: String = prefixCorrectionEnabled
            ? prefixCorrector.correctedPrefix(userTail, detectedLanguage: detectedLanguage)
            : userTail
        let baseSystemPrompt = ModelRuntime.buildSystemPrompt(detectedLanguage: detectedLanguage)
        var systemParts: [String] = [baseSystemPrompt]
        if !customInstructions.isEmpty {
            systemParts.append("Style and persona:\n\(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !contextPrefix.isEmpty {
            systemParts.append("Context:\n\(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let systemMessage = systemParts.joined(separator: "\n\n")

        var parts: [String] = []
        if !customInstructions.isEmpty {
            parts.append(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !contextPrefix.isEmpty {
            parts.append(contextPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let basePreamble = parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"

        // Dump the assembled prompt skeleton the LLM will actually receive.
        // `|||SYS|||` / `|||PREAMBLE|||` / `|||TAIL|||` separators keep the
        // payload single-line and grep-friendly while preserving the three
        // slots distinctly — lets us cross-reference what's in /tmp/souffleuse-ocr.log
        // against what actually reaches the model.
        PredictDebug.log(
            "final_prompt",
            "sys=\(systemMessage.debugDescription) |||PREAMBLE||| \(basePreamble.debugDescription) |||TAIL||| \(correctedTail.debugDescription)"
        )

        let maxTokens = self.maxTokens
        let isInstructModel = modelId.range(of: "-it", options: .caseInsensitive) != nil
            || modelId.range(of: "instruct", options: .caseInsensitive) != nil

        // Phase 4 — lifecycle owned by GenerationPlanner. The variant
        // `beginGenerationDetachingPrevious()` cancels the previous Task,
        // bumps the counter, AND returns the previousTask so the new Task
        // below can `await previousTask?.value` (preserves cross-stream
        // finalisation ordering).
        let (myGeneration, previousTask) = planner.beginGenerationDetachingPrevious()

        // Snapshot personalisation inputs to satisfy the Sendable closure
        // boundary. Strength + history are read here so the detached Task can
        // `await` them without touching @MainActor state inside the
        // runtime.generate closure.
        let personalizationStrength = self.personalizationStrength
        // Hoisted on the @MainActor side (self is strong here) so the detached
        // generation Task can use it without touching @MainActor state. Filtered
        // to `.prose` (never accept-fragments) AND débarrassé des entrées qui ne
        // sont QU'une salutation : injectées comme démonstration few-shot dans le
        // prompt du modèle PT base, elles ré-amorcent la pollution multi-salutations
        // (« Coucou… » → « Bonjour… », cf. le raisonnement de retrait plus bas).
        // Elles restent dans `historySnapshot` complet, donc le biais n-gram et
        // `strongCorpusMatch` rappellent toujours les salutations de l'utilisateur
        // — on ne les retire QUE comme exemple imitable. Ceci est le pool
        // d'injection few-shot (B-prompt).
        let proseExamplesPool = FewShotScoping.scopedExamplesPool(self.historySnapshot, activeDomain: activeDomain)

        let baseSystem = baseSystemPrompt
        let customInstr = customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ctxPrefix = contextPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // ── Phase 2: fieldContext slot body (D-15c French annotation) ──
        let fieldContextSlot: String = {
            guard let snap = axSnapshot else { return "" }
            var lines: [String] = []
            if let label = PromptBuilder.roleLabelFR(role: snap.role, subrole: snap.subrole) {
                lines.append("Champ : \(label).")
            }
            if let placeholder = snap.placeholder?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !placeholder.isEmpty {
                lines.append("Placeholder : « \(placeholder) ».")
            }
            if let help = snap.help?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !help.isEmpty {
                lines.append("Aide : « \(help) ».")
            }
            return lines.joined(separator: "\n")
        }()
        // ── Phase 2: afterCursor slot body (D-14 prose-FR delimiter) ──
        let afterCursorSlot: String = {
            guard let snap = axSnapshot,
                  let after = snap.textAfterCaret?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !after.isEmpty else { return "" }
            return "Suite du texte (à ne pas répéter) : « \(after) »."
        }()

        let runtime = self.runtime

        // If a previous LLM Task was running, its cancellation may have left
        // the KV cache in a state inconsistent with what the holder records
        // (Swift offset advanced but MLX GPU update interrupted mid-step).
        // Force-invalidate before the next generation reads the cache to
        // avoid a MLX assertion in `KVCacheSimple.update` (race observed
        // 2026-05-26 after partial-accept Tab: two back-to-back kv_cache_extend
        // events triggered a slice update assert in MLX).
        //
        // Cost: re-prefill on the next predict only if a cancellation
        // occurred. Normal predict-after-typing keeps cache extend.
        let hadInFlightCancellation = (previousTask != nil)
        if hadInFlightCancellation {
            cache.invalidate(reason: .explicit)
            Log.info(.predictor, "kv_cache_invalidate_on_cancel")
        }

        // Stale-ghost guard : track whether THIS generation ever produced a
        // ghost the user should see (a valid non-empty LLM chunk, OR an empty
        // chunk that legitimately fell back to a valid instant ghost). When a
        // generation drops EVERY token (all guards in `generateLlama` fire and
        // `acc.lastEmitted` stays "" so `onChunk("")` is never called), this
        // box stays false. The completion block below then clears any leftover
        // ghost from a PREVIOUS keystroke — UNLESS the current prefix has a
        // valid instant ghost (L0 word-completion or strong corpus fast-path),
        // which must be preserved (anti-churn). `emittedGhost` is mutated only
        // on @MainActor (the onChunk closure and the completion block).
        let emitTracker = GhostEmissionTracker()

        let task = Task { [weak self] in
            _ = await previousTask?.value
            if Task.isCancelled { return }

            // Personalization : n-gram logit bias only (post 04-07 + tightening).
            //
            // Drop few-shot retrieval — the "PT base model + raw-concat
            // examples" combo polluted ghost output via in-context learning
            // (e.g. "Coucou, ceci est un test " → "Bonjour, c" because a
            // history entry started with "Bonjour, c…"). The LLM read
            // concatenated examples as document context, not as labelled
            // demonstrations, and continued the apparent "multi-greeting"
            // pattern.
            //
            // The right architectural place for user personalization is the
            // sampler — the llama engine applies user-typed token frequencies
            // (the accepted-text corpus n-gram, fed via `runtime.setCorpus`) as
            // per-token logit bias during generation, without ever injecting
            // demonstration text into the prompt. This eliminates cross-
            // pollination by construction.
            //
            // LLM input window : feed the last `llmContextWindowChars` of the
            // CORRECTED prefix to the model as `beforeCursor`. The full 2048-char
            // userTail still drives memoisation / anti-repeat below; only the
            // bytes the LLM SEES are corrected and windowed. Sized by the
            // 2026-05-29 window A/B (see Tuning.llmContextWindowChars): 512 was
            // the worst window (a mid-sentence cut severs the discourse thread →
            // generic filler); 1024 recovers far-antecedent coherence with no
            // within-window regression, ~+60ms warm prefill paid once per cold
            // field. The old "more context dilutes a 1B model" rationale was
            // measured and refuted.
            let llmTail = String(correctedTail.suffix(SuggestionPolicy.Tuning.llmContextWindowChars))
            let basePromptText = basePreamble + llmTail

            // Few-shot prose injection (B-prompt, 2026-05-30). Retrieve the user's
            // own past PROSE (never accept-fragments) most relevant to the current
            // tail, topped up with recent prose so injection fires whenever the
            // corpus holds prose. Scoped by generic CLUSTER, never by exact
            // bundleID (P1.2): `proseExamplesPool` keeps only the prose of apps in
            // the SAME registre cluster as the focus app (or all prose when
            // `activeDomain == .other`). Cluster — not exact-bundle — is the right
            // grain because apps of one registre share a writing style, and
            // unrelated registres (private `.chat`, `.code`) must never leak as
            // style demonstrations. Known gap: corpus-import tags seeded Intercom
            // prose `com.intercom.conversations` → `.other`, while live support is
            // typed in `com.brave.Browser` → `.web`; these land in DIFFERENT
            // clusters, so seeds don't reach live use until the seeder re-tags to
            // the target app's bundleID (P2.3 `SouffleuseCorpusSeed --as-bundle`).
            // The injected count is logged so the "full corpus / empty prompt"
            // failure mode stays visible. Synchronous in-memory scan over
            // historySnapshot (≤200 entries, <5ms) — no TTFT impact.
            var examplesBlock = ""
            if personalizationStrength > 0 && SuggestionPolicy.Tuning.examplesInjectionEnabled {
                let prose = proseExamplesPool
                // Only inject genuinely-similar examples (ranked by Jaccard over
                // the current userTail). We deliberately do NOT backfill with
                // arbitrary prose when fewer than defaultK match: padding the
                // prompt with unrelated past lines hurt relevance and could leak
                // a specific, unrelated sentence the user typed into the model's
                // context. Nothing similar ⇒ inject nothing.
                // TO REVERT: re-add the `if examples.count < defaultK { … }` backfill loop.
                let examples = SimilarHistoryRetrieval.rank(
                    entries: prose, userTail: userTail, limit: SimilarHistoryRetrieval.defaultK
                )
                examplesBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: examples)
                if !examples.isEmpty {
                    Log.info(.predictor, "ghost_examples_injected", count: examples.count)
                }
            }

            if Task.isCancelled { return }

            let request = PredictRequest(
                prefix: prefix,
                contextPrefix: contextPrefix,
                customInstructions: customInstructions,
                axSnapshotPlaceholder: axSnapshot?.placeholder,
                axSnapshotHelp: axSnapshot?.help,
                axSnapshotRole: axSnapshot?.role,
                axSnapshotSubrole: axSnapshot?.subrole,
                axTextAfterCaret: axSnapshot?.textAfterCaret,
                personalizationStrength: Double(personalizationStrength),
                maxTokens: maxTokens,
                maxWords: maxWords,
                detectedLanguage: detectedLanguage,
                token: myGeneration,
                userTail: userTail,
                llmTail: llmTail,
                isInstructModel: isInstructModel,
                systemMessage: systemMessage,
                baseSystem: baseSystem,
                customInstr: customInstr,
                ctxPrefix: ctxPrefix,
                fieldContextSlot: fieldContextSlot,
                afterCursorSlot: afterCursorSlot,
                basePreamble: basePreamble,
                examplesBlock: examplesBlock,
                basePromptText: basePromptText
            )

            // ── Cœur LLM beam (flag SOUFFLEUSE_BEAM_CORE) ───────────────────
            // Sous le flag, le beam est le SEUL chemin LLM : on court-circuite
            // l'escalade / long-ghost / streaming. `routeInstant` reste devant —
            // si un ghost instant (L0/L1) est déjà affiché (`!instantGhost.isEmpty`)
            // on ne le clobber JAMAIS avec le LLM (parité long-ghost / §2). Sinon
            // le beam génère (one-shot pour l'instant ; le reuse HIT/MISS viendra
            // au commit 4). Le flag OFF (ou beam non chargé) rend `useBeamCore`
            // faux → ce bloc est mort, chemin actuel byte-identique.
            if useBeamCore {
                guard instantGhost.isEmpty else { return }   // recall en avant : pas de LLM
                let beam = await runtime.generateGhostBeam(request: request)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, self.planner.isCurrent(myGeneration) else { return }
                    if let beam, beam.show {
                        let word = ModelRuntime.OutputFilter.normalizeFrenchTypography(beam.word)
                        let score = SuggestionPolicy.score(source: .llm, ghost: beam.word, userTail: userTail)
                        self.policy.applyGhost(beam.word, source: .llm, score: score, userTail: userTail)
                        self.suggestion = word
                        self.predictedForPrefix = forPrefix
                        self.suggestionSource = .llm
                        // Living ghost : sous le beam-core, c'est le REFILL natif de
                        // la réserve (advance → top-up) qui prolonge le ghost, PAS le
                        // rolling-refill greedy. On le COUPE (`false`) pour qu'il
                        // n'appende pas du texte greedy par-dessus le ghost beam.
                        self.ghostRollingAllowed = false
                        // Alimente le CompletionCache (couche instant + undo-as-ghost),
                        // comme le fait le long-ghost.
                        self.cache.store(prefix: userTail, suggestion: word)
                        Log.info(.predictor, "ghost_beam_core_shown", count: word.count)
                        GhostInspector.shared.record(tail: userTail, verdict: .shown, source: .llm,
                                                     reason: beam.reason, content: word, score: score)
                    } else {
                        // Rien à montrer : nettoie un ghost PÉRIMÉ d'une frappe
                        // précédente (instantGhost est vide ici). Même garde que le
                        // stale-clear du bloc de complétion du streaming.
                        self.ghostRollingAllowed = true
                        if Self.shouldClearStaleGhost(
                            emittedGhost: false, instantGhost: instantGhost,
                            displayedSuggestion: self.suggestion
                        ) {
                            Log.info(.predictor, "ghost_cleared_stale", count: self.suggestion.count)
                            self.suggestion = ""
                            self.predictedForPrefix = ""
                            self.suggestionSource = .none
                            self.policy.reset()
                        }
                        Log.info(.predictor, "ghost_beam_core_hidden")
                        GhostInspector.shared.record(tail: userTail, verdict: .gated, source: .llm,
                                                     reason: beam?.reason ?? "beam-nil", content: beam?.word ?? "(rien)")
                    }
                }
                return
            }

            // ── Frame C (F1) : escalade mid-mot — passe greedy + dico, HORS stream.
            // Court-circuite le streaming `onChunk` (qui referait `midword_block`) :
            // on décide ici, puis on applique nous-mêmes le ghost (fast-accept) ou
            // on retombe sur l'instant (hide). Le flag OFF rend `useMidWordEscalation`
            // ET `useAfterSpaceLongGhost` toujours faux → ce bloc est mort et le
            // streaming ci-dessous inchangé (byte-identique).
            //
            // `useAfterSpaceLongGhost` (flag long-ghost ON, caret à la frontière,
            // pas de recall corpus) emprunte le MÊME chemin long-ghost unifié : il
            // implique `midWordLongGhostEnabled`, donc la sous-branche long-ghost
            // ci-dessous tire (jamais l'escalade F1/F2/F3, réservée au mid-mot).
            if useMidWordEscalation || useAfterSpaceLongGhost {
                // A/B : chemin SIMPLIFIÉ (single greedy healed) vs escalade complète.
                // Le long-ghost est affiché par les MÊMES lignes que l'escalade
                // (self.suggestion = …, source, predictedForPrefix), HORS stream.
                // `useAfterSpaceLongGhost ⇒ midWordLongGhostEnabled`, donc l'après-
                // espace passe TOUJOURS par cette sous-branche (et jamais l'escalade).
                if SuggestionPolicy.Tuning.midWordLongGhostEnabled {
                    // STREAMING (flag) : peint chaque partiel dès qu'il sort, via
                    // l'instant-paint (observation sur `suggestion`). Freshness =
                    // `planner.isCurrent` + `predictedForPrefix == forPrefix`. La
                    // finalisation ci-dessous remplace par le résultat pleinement gaté.
                    let onPartial: (@Sendable (String) -> Void)?
                    if SuggestionPolicy.Tuning.ghostStreamEnabled {
                        onPartial = { [weak self] partial in
                            Task { @MainActor in
                                guard let self, self.planner.isCurrent(myGeneration) else { return }
                                self.suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(partial)
                                self.predictedForPrefix = forPrefix
                                self.suggestionSource = .llm
                            }
                        }
                    } else {
                        onPartial = nil
                    }
                    let lg = await runtime.midWordLongGhost(request: request, onPartial: onPartial)
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.planner.isCurrent(myGeneration) else { return }
                        if let lg, lg.show {
                            let word = ModelRuntime.OutputFilter.normalizeFrenchTypography(lg.word)
                            let score = SuggestionPolicy.score(source: .llm, ghost: lg.word, userTail: userTail)
                            self.policy.applyGhost(lg.word, source: .llm, score: score, userTail: userTail)
                            self.suggestion = word
                            self.predictedForPrefix = forPrefix
                            self.suggestionSource = .llm
                            // Gradient d'engagement (flag MW_ENGAGEMENT) : PLEIN autorise le
                            // rolling (living ghost), PRUDENT le FIGE. Hors flag, `rollingAllowed`
                            // est toujours `true` (engagement .plein par défaut) → comportement
                            // de roulement inchangé. Lu par `maybeSpawnRollingRefill`.
                            self.ghostRollingAllowed = lg.rollingAllowed
                            // Alimente le CompletionCache (comme le fait le streaming en
                            // ~1047) pour que `undo-as-ghost` (PVM:515) puisse restaurer
                            // le ghost au backspace : « Madame, »→« Monsieur », efface
                            // « , » → longestExtendingKey trouve « Madame, » → « , Monsieur ».
                            self.cache.store(prefix: userTail, suggestion: word)
                            Log.info(.predictor, "ghost_midword_longghost_shown", count: word.count)
                            // Inspecteur : un `reason` DISTINCT par niveau d'engagement
                            // (engage:plein / engage:prudent) quand le gradient est actif,
                            // sinon "longghost" (inchangé). Observable en live.
                            GhostInspector.shared.record(tail: userTail, verdict: .shown, source: .llm,
                                                         reason: SuggestionPolicy.Tuning.midWordEngagementEnabled
                                                            ? lg.engagement.inspectorReason : "longghost",
                                                         content: word, score: score)
                        } else {
                            // ZÉRO (ou hide) : rien d'affiché → le rolling n'a aucun ghost à
                            // rouler ; on remet `rollingAllowed` à true (état neutre) pour ne
                            // pas figer un ghost FUTUR émis par un autre chemin.
                            self.ghostRollingAllowed = true
                            self.suggestion = instantGhost
                            self.predictedForPrefix = forPrefix
                            self.suggestionSource = instantSource
                            Log.info(.predictor, "ghost_midword_longghost_hidden")
                            GhostInspector.shared.record(tail: userTail, verdict: .gated, source: .llm,
                                                         reason: lg?.reason ?? "longghost-nil", content: lg?.word ?? "(rien)")
                        }
                    }
                    return
                }
                let esc = await runtime.midWordEscalate(request: request)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self, self.planner.isCurrent(myGeneration) else { return }
                    if let esc, esc.show {
                        let word = ModelRuntime.OutputFilter.normalizeFrenchTypography(esc.word)
                        let score = SuggestionPolicy.score(source: .llm, ghost: esc.word, userTail: userTail)
                        self.policy.applyGhost(esc.word, source: .llm, score: score, userTail: userTail)
                        self.suggestion = word
                        self.predictedForPrefix = forPrefix
                        self.suggestionSource = .llm
                        Log.info(.predictor, "ghost_midword_escalation_shown", count: word.count)
                        GhostInspector.shared.record(tail: userTail, verdict: .shown, source: .llm,
                                                     reason: "escalade \(esc.reason)", content: word, score: score)
                    } else if SuggestionPolicy.Tuning.midWordL0Fallback,
                              let comp = self.wordCompleter.commonCompletion(
                                  for: userTail, minLen: SuggestionPolicy.Tuning.escL0MinPartial),
                              comp.count >= SuggestionPolicy.Tuning.escL0MinCompletion {
                        // F3 — DERNIER RECOURS : le LLM a fumblé, le dico connaît le
                        // mot (« pingou »→« pingouin »). Complétion COMMUNE nette →
                        // on la montre comme L0 (aveugle au contexte mais sur un mot
                        // quasi-déterminé, donc fiable).
                        let word = ModelRuntime.OutputFilter.normalizeFrenchTypography(comp)
                        let score = SuggestionPolicy.score(source: .wordComplete, ghost: comp, userTail: userTail)
                        self.policy.applyGhost(comp, source: .wordComplete, score: score, userTail: userTail)
                        self.suggestion = word
                        self.predictedForPrefix = forPrefix
                        self.suggestionSource = .wordComplete
                        Log.info(.predictor, "ghost_midword_l0_fallback", count: comp.count)
                        GhostInspector.shared.record(tail: userTail, verdict: .shown, source: .wordComplete,
                                                     reason: "L0 dico (esc \(esc?.reason ?? "hide"))", content: word, score: score)
                    } else {
                        // Caché (fast-reject / branches divergentes, et pas de
                        // fallback dico) : retombe sur le ghost instant, comme la
                        // branche `chunk.isEmpty` du streaming.
                        self.suggestion = instantGhost
                        self.predictedForPrefix = forPrefix
                        self.suggestionSource = instantSource
                        Log.info(.predictor, "ghost_midword_escalation_hidden")
                        GhostInspector.shared.record(tail: userTail, verdict: .gated, source: .llm,
                                                     reason: "escalade \(esc?.reason ?? "hide")", content: esc?.word ?? "(rien)")
                    }
                }
                return
            }

            // Chunk callback : Relevance Gate apply + observable update.
            // Empty chunks are the anti-repeat drop signal — fall back to
            // whichever instant-path ghost was set (history hit beats word
            // completion, both beat empty).
            let metrics = await runtime.generate(request: request) { @MainActor chunk in
                guard let self else { return }
                guard self.planner.isCurrent(myGeneration) else { return }
                if chunk.isEmpty {
                    // A drop guard in `generateLlama` reset its previously-
                    // emitted ghost. Fall back to whichever instant-path ghost
                    // was computed for the CURRENT prefix (history beats word-
                    // completion, both beat empty). This IS a deliberate ghost
                    // state for the current prefix — mark emitted so the
                    // completion block doesn't treat it as a no-output stale case.
                    emitTracker.emitted = true
                    Log.info(.predictor, "ghost_dropped_repeat")
                    PredictDebug.log("ghost_dropped_repeat", "fallback_to_instant=\(instantGhost.debugDescription)")
                    // Le chunk LLM est dropé, MAIS on retombe sur le ghost INSTANT
                    // (corpus / complétion système) : s'il est non-vide il EST
                    // affiché → on le marque « affiché (instant) » et non « drop »,
                    // sinon l'inspecteur ment (rien vs ghost réel à l'écran).
                    if instantGhost.isEmpty {
                        GhostInspector.shared.record(tail: userTail, verdict: .dropped, source: .none,
                                                     reason: "LLM dropé · rien à montrer", content: "(rien)")
                    } else {
                        GhostInspector.shared.record(tail: userTail, verdict: .shown, source: instantSource,
                                                     reason: "instant (LLM dropé)", content: instantGhost)
                    }
                    self.suggestion = instantGhost
                    self.predictedForPrefix = forPrefix
                    self.suggestionSource = instantSource
                    return
                }
                // Phase 4 D-07 : Relevance Gate replaces the old anti-churn
                // rule. `policy.onLLMChunk` applies :
                //   1. Mid-word ALLOWED (D-08 unblocked) — coherence already
                //      enforced upstream in generateLlama's coherence guard
                //   2. passesGate floor (0.25) — ghost_gate_block
                //   3. Replacement bar (1.15) OR L2-upgrades-L1 delta (0.15)
                //      — ghost_keep_under_bar
                //   4. Parasite detection si remplacement < parasiteWindow
                //      — ghost_classified_parasite
                guard let update = self.policy.onLLMChunk(chunk, userTail: userTail) else {
                    PredictDebug.log("chunk_gated", "oneLine=\(chunk.debugDescription) current=\(self.suggestion.debugDescription) source=\(self.suggestionSource)")
                    GhostInspector.shared.record(tail: userTail, verdict: .gated, source: .llm,
                                                 reason: self.policy.lastGateReason, content: chunk)
                    return
                }
                // Anti-répétition de contenu : rogne un chunk LLM qui redonne le
                // mot déjà tapé (« …bonjour » → « bonjour, comment… »). Filet de
                // sécurité distinct du `ghostIsRepeatingPrefix` interne au stream
                // (qui manque le cas mot-complet-sans-séparateur). Un chunk qui
                // n'est QUE la répétition retombe sur le ghost instant, comme la
                // branche `chunk.isEmpty` ci-dessus. La gate stub tourne ENSUITE
                // sur le texte dédupliqué (un résidu d'un seul caractère est bien
                // du bruit à écarter).
                let ghostText = SuggestionPolicy.dedupLeadingRepeat(
                    ghost: update.text, userTail: userTail)
                guard !ghostText.isEmpty else {
                    // Le chunk ACCUMULÉ n'est pour l'instant QUE la répétition du
                    // mot tapé (la suite n'est pas encore arrivée). On NE touche
                    // PAS à l'affichage et on attend le token suivant — sinon le
                    // ghost clignote à chaque démarrage de stream. `emitted` reste
                    // tel quel : si la génération se termine sans jamais produire
                    // de suite, le stale-clear du bloc de complétion s'en charge.
                    Log.info(.predictor, "ghost_dropped_repeat")
                    PredictDebug.log("ghost_repeat_wait", "raw=\(update.text.debugDescription) userTail=\(userTail.debugDescription)")
                    return
                }
                // Stub guard : a fresh NEXT-WORD ghost (caret at a word
                // boundary — userTail ends in space/punct/empty) that is just a
                // single character ("m") is noise. The user can't read intent
                // from one letter, and it's almost always a streaming stub whose
                // continuation got gated out (base-model junk like repeated
                // "fraises"/`<strong>` tags, or an over-eager corpus bias that
                // flips only the first token). Skip it and wait for ≥2 chars —
                // nothing beats a lone "m". Mid-word completions (caret inside a
                // word, finishing it: "Bonjou" → "r") are exempt: there the last
                // userTail char is a letter, so this never fires.
                if Self.isNextWordStub(userTail: userTail, ghost: ghostText)
                    || Self.isMidWordStub(userTail: userTail, ghost: ghostText) {
                    PredictDebug.log("chunk_stub_skip", "text=\(ghostText.debugDescription) userTail=\(userTail.debugDescription)")
                    GhostInspector.shared.record(tail: userTail, verdict: .stub, source: .llm, reason: "stub_1char", content: ghostText)
                    return
                }
                let fromHigh = (self.suggestionSource == .history
                             || self.suggestionSource == .cache
                             || self.suggestionSource == .undoCache)
                Log.info(.predictor,
                         fromHigh ? "ghost_swap_to_llm_from_high" : "ghost_apply_llm",
                         count: ghostText.count)
                PredictDebug.log("chunk_applied", "oneLine=\(ghostText.debugDescription) prev_source=\(self.suggestionSource)")
                GhostInspector.shared.record(tail: userTail, verdict: .shown, source: .llm,
                                             reason: "stream", content: ghostText, score: update.score)
                emitTracker.emitted = true
                // Re-score quand la dédup a raccourci le texte : `update.score` a
                // été calculé par onLLMChunk sur le chunk BRUT (avec la
                // répétition). Le stocker tel quel gonfle `currentScore`, et la
                // barre de remplacement (×1.15) bloquerait alors les extensions
                // légitimes du chunk suivant — le ghost se fige sur le premier
                // bout dédupliqué (le bug « le LLM ne tourne plus »). On score ce
                // qui est RÉELLEMENT affiché.
                let appliedScore = ghostText == update.text
                    ? update.score
                    : SuggestionPolicy.score(source: .llm, ghost: ghostText, userTail: userTail)
                self.policy.applyGhost(ghostText, source: .llm, score: appliedScore, userTail: userTail)
                self.suggestion = ModelRuntime.OutputFilter.normalizeFrenchTypography(ghostText)
                self.predictedForPrefix = forPrefix
                self.suggestionSource = .llm
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                guard self.planner.isCurrent(myGeneration) else { return }

                // Stale-ghost clear : this generation finished without ever
                // emitting a ghost for the current prefix (every token dropped
                // by the coherence / degenerate / instruction-echo / repeat
                // guards, and the all-dropped case never reaches the
                // `onChunk("")` reset inside generateLlama). Whatever is still
                // displayed therefore belongs to an OLD keystroke's prefix — it
                // is stale (the "faique" repro : prefix "…fai", leftover ghost
                // "que"). Clear it so the user sees nothing rather than a
                // mismatched ghost.
                //
                // Anti-churn : we ONLY clear when the current prefix produced no
                // valid instant ghost (`instantGhost.isEmpty`). A fresh L0
                // word-completion or a strong corpus `.history` fast-path for
                // the CURRENT prefix yields a non-empty `instantGhost`, is still
                // displayed, and is protected here — an empty LLM stream never
                // wipes a valid current-prefix ghost. Cache / undo-cache hits
                // return before generation and never reach this path.
                if Self.shouldClearStaleGhost(
                    emittedGhost: emitTracker.emitted,
                    instantGhost: instantGhost,
                    displayedSuggestion: self.suggestion
                ) {
                    Log.info(.predictor, "ghost_cleared_stale", count: self.suggestion.count)
                    PredictDebug.log("ghost_cleared_stale", "userTail=\(userTail.debugDescription) cleared=\(self.suggestion.debugDescription)")
                    self.suggestion = ""
                    self.predictedForPrefix = ""
                    self.suggestionSource = .none
                    self.policy.reset()
                }

                if let m = metrics {
                    self.ttftMillis = m.ttftMillis
                    self.tokensPerSecond = m.tokensPerSecond
                    // Coarse proxy : char/4 ≈ SentencePiece BPE for Latin
                    // script. The absolute value is only useful for
                    // debugging ; the gate metric is the RATIO of this
                    // event to `predict_called`. KV-07.
                    let producedTokens = self.suggestion.isEmpty ? 0 : max(1, self.suggestion.count / 4)
                    if let ttft = m.ttftMillis {
                        Log.info(.predictor, "predict_ttft", count: ttft)
                    }
                    Log.info(.predictor, "llm_done_stored", count: producedTokens)
                    PredictDebug.log("llm_done_stored", "userTail=\(userTail.debugDescription) final=\(self.suggestion.debugDescription) ttft=\(m.ttftMillis ?? -1)ms")
                    self.cache.store(prefix: userTail, suggestion: self.suggestion)
                }
            }
        }
        planner.setCurrentTask(task)
    }

    /// **Rolling-refill : prolonge le ghost affiché** (mode sliding-window,
    /// parité Cotypist, flag `midWordGhostRollingEnabled`). Génère le(s) mot(s)
    /// SUIVANT(s) en continuant depuis le texte VISIBLE complet = ce que
    /// l'utilisateur a tapé/validé (`committedText`) PLUS le reste encore non
    /// consommé (`currentRemainder`). On enchaîne donc après une frontière
    /// PROPRE (fin du reste) → pas de `healPrefix`.
    ///
    /// UNE passe greedy off-main (comme `predict`), post-traitée par les mêmes
    /// helpers `OutputFilter`. Renvoie le texte à APPENDRE au reste (avec un
    /// unique espace de tête pour la concaténation), ou `nil` si rien
    /// d'exploitable. Les gardes de génération (`planner.isCurrent`) empêchent
    /// un refill périmé d'aboutir si une vraie `predict()` a démarré entre-temps ;
    /// le call-site (AppDelegate) re-valide en plus l'état avant d'appender.
    func extendGhost(committedText: String, currentRemainder: String, maxWords: Int) async -> String? {
        guard runtime.canGenerate, maxWords >= 1 else { return nil }

        // Texte visible complet : ce qui pilote la continuation du modèle.
        let fullVisible = committedText + currentRemainder
        let userTail = String(fullVisible.suffix(Self.userTailCap))

        // Steering de langue (même logique sticky que `predict`).
        if let confident = ModelRuntime.detectLanguage(in: userTail) {
            lastDetectedLanguage = confident
        }
        let detectedLanguage = lastDetectedLanguage
        let correctedTail: String = prefixCorrectionEnabled
            ? prefixCorrector.correctedPrefix(userTail, detectedLanguage: detectedLanguage)
            : userTail
        let baseSystemPrompt = ModelRuntime.buildSystemPrompt(detectedLanguage: detectedLanguage)
        let systemMessage = baseSystemPrompt
        let llmTail = String(correctedTail.suffix(SuggestionPolicy.Tuning.llmContextWindowChars))
        let isInstructModel = modelId.range(of: "-it", options: .caseInsensitive) != nil
            || modelId.range(of: "instruct", options: .caseInsensitive) != nil

        // Capture la génération COURANTE sans la bumper : si une vraie predict()
        // démarre pendant le refill, elle incrémente le compteur et notre token
        // capturé devient non-courant → le refill est droppé (anti-stale-append).
        let myGeneration = planner.currentGeneration
        let maxTokens = self.maxTokens
        let runtime = self.runtime

        // Few-shot stylé sur le refill glissant (P1.3) : même mécanisme que
        // `predict()`, scopé sur le cluster du dernier predict (`lastActiveDomain`)
        // pour que la continuation reste dans le bon registre. Gardé par le maître
        // (`personalizationStrength`) — le style suit le toggle de perso. Le biais
        // corpus reste OFF sur le refill (`personalizationStrength: 0` ci-dessous,
        // orthogonal). Rank synchrone in-memory (<5ms) — hors chemin chaud TTFT.
        var refillExamplesBlock = ""
        if personalizationStrength > 0 && SuggestionPolicy.Tuning.examplesInjectionEnabled {
            let prose = FewShotScoping.scopedExamplesPool(self.historySnapshot, activeDomain: lastActiveDomain)
            let examples = SimilarHistoryRetrieval.rank(
                entries: prose, userTail: userTail, limit: SimilarHistoryRetrieval.defaultK
            )
            refillExamplesBlock = SimilarHistoryRetrieval.buildExamplesBlock(from: examples)
            if !examples.isEmpty {
                Log.info(.predictor, "ghost_refill_examples_injected", count: examples.count)
            }
        }

        let request = PredictRequest(
            prefix: fullVisible,
            contextPrefix: "",
            customInstructions: "",
            axSnapshotPlaceholder: nil,
            axSnapshotHelp: nil,
            axSnapshotRole: nil,
            axSnapshotSubrole: nil,
            axTextAfterCaret: nil,
            personalizationStrength: 0,
            maxTokens: maxTokens,
            maxWords: maxWords,
            detectedLanguage: detectedLanguage,
            token: myGeneration,
            userTail: userTail,
            llmTail: llmTail,
            isInstructModel: isInstructModel,
            systemMessage: systemMessage,
            baseSystem: baseSystemPrompt,
            customInstr: "",
            ctxPrefix: "",
            fieldContextSlot: "",
            afterCursorSlot: "",
            basePreamble: "",
            examplesBlock: refillExamplesBlock,
            basePromptText: llmTail
        )

        let extension_ = await runtime.extendGhost(request: request, maxWords: maxWords)
        // NOTE : on ne re-checke PLUS `planner.isCurrent(myGeneration)` ici. Ce garde
        // jetait des refills VALIDES : dès que tu finis de consommer un mot, `predict()`
        // bumpe le compteur de génération → l'extension (pourtant pour le bon bord droit)
        // était nil-ée avant même d'atteindre l'AppDelegate. La cohérence est désormais
        // assurée par la re-validation TOLÉRANTE du call-site (mêmes ancres, conso sur le
        // même chemin, bord droit intact), qui est la garde autoritaire pour le refill.
        guard let extension_, !extension_.isEmpty else { return nil }
        Log.info(.predictor, "ghost_rolling_refill", count: extension_.count)
        return extension_
    }

    /// Rebuilds the personalization corpus from a list of accepted entries.
    /// Called at startup (with everything from `TypingHistoryStore`) and after
    /// "Tout supprimer". Feeds the accepted strings into the llama engine, which
    /// rebuilds its llama-token-id corpus n-gram (the live personalization bias).
    func rebuildPersonalization(from entries: [TypingHistoryEntry]) async {
        // Layer 1 snapshot refresh — done first so the instant path becomes
        // operational even if the n-gram tokenisation below takes its time.
        // TypingHistoryStore.entries is oldest-first; we reverse so the
        // linear scan in SuggestionPolicy's exact-substring helper hits
        // freshest first (matches ingestAccepted's insert-at-0 ordering).
        self.historySnapshot = Array(entries.reversed())
        // Personal lexicon refresh, in lockstep with the snapshot (same corpus).
        self.learnedLexicon = LearnedLexicon.build(from: self.historySnapshot)

        // Phase 1 personalization : rebuild the llama-token-id corpus n-gram
        // inside the engine. This is the path that biases the llama.cpp
        // decoder. Strings are the accepted text, prefixed by their context
        // when present.
        let corpus = entries.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)
    }

    /// Builds the corpus training string for one accepted entry — the accepted
    /// text, prefixed by its preceding context when present. Shared by both the
    /// full rebuild and the incremental accept path so the llama-token-id
    /// n-gram sees a consistent shape.
    static func corpusString(for entry: TypingHistoryEntry) -> String {
        entry.contextBefore.isEmpty
            ? entry.accepted
            : entry.contextBefore + " " + entry.accepted
    }

    /// Folds a single newly-accepted entry into the personalization corpus.
    func ingestAccepted(_ entry: TypingHistoryEntry) async {
        // Garde d'admission UNIQUE (partagée avec `TypingHistoryStore.append`).
        // Avant, seul le secret était filtré ici (P1.5) ; les 3 autres gardes du
        // disque (longueur <3, fragment "s de", mot tronqué mid-glue) ne l'étaient
        // PAS — un tel payload accepté entrait dans le snapshot mémoire (lexique +
        // biais n-gram de la session) puis disparaissait au redémarrage, créant une
        // divergence mémoire↔disque. On consulte désormais la même décision : la
        // mémoire applique exactement les 4 mêmes gardes que le disque.
        if let reason = TypingHistoryStore.admissionRejection(
            contextBefore: entry.contextBefore,
            accepted: entry.accepted,
            typoDetector: typoDetector
        ) {
            Log.info(.context, reason == .secretLike ? "ingest_skipped_secretlike" : "ingest_skipped_inadmissible")
            return
        }
        // Layer 1 snapshot append — keep most-recent-first ordering so the
        // linear scan in SuggestionPolicy's exact-substring helper hits
        // fresh entries first. Cap mirrors TypingHistoryStore.maxEntries (200).
        self.historySnapshot.insert(entry, at: 0)
        if self.historySnapshot.count > 200 {
            self.historySnapshot.removeLast(self.historySnapshot.count - 200)
        }
        // Keep the personal lexicon current with the freshly-accepted term so a
        // brand the user just typed is offerable on its next occurrence.
        self.learnedLexicon = LearnedLexicon.build(from: self.historySnapshot)

        // Refresh the llama corpus n-gram so the just-accepted continuation is
        // immediately available to bias the decoder. The corpus is small, so a
        // full rebuild from the (capped) snapshot is cheap and avoids tracking
        // incremental n-gram deltas inside the engine.
        let corpus = self.historySnapshot.map { Self.corpusString(for: $0) }
        await runtime.setCorpus(corpus)
    }

    /// Pure decision for the stale-ghost clear (extracted for unit testing).
    ///
    /// Returns `true` when the just-finished generation left the displayed
    /// ghost in a stale state that must be cleared :
    ///   - `emittedGhost == false` : this generation never set a ghost for the
    ///     current prefix (every token dropped by the coherence / degenerate /
    ///     instruction-echo / repeat guards, and the all-dropped case never
    ///     fired the `onChunk("")` reset inside `generateLlama`).
    ///   - `instantGhost.isEmpty` : the current prefix's instant cascade (L0
    ///     word-completion / strong corpus fast-path) produced nothing either,
    ///     so no valid current-prefix ghost is being shown.
    ///   - `displayedSuggestion` non-empty : there IS a leftover ghost on screen.
    ///
    /// When all three hold, the on-screen ghost belongs to an OLD/diverged
    /// prefix (the "faique" repro) → clear. Conversely, a non-empty
    /// `instantGhost` means a valid current-prefix L0/corpus ghost is displayed
    /// and MUST be preserved (anti-churn) — an empty LLM stream never wipes it.
    static func shouldClearStaleGhost(
        emittedGhost: Bool,
        instantGhost: String,
        displayedSuggestion: String
    ) -> Bool {
        !emittedGhost && instantGhost.isEmpty && !displayedSuggestion.isEmpty
    }

    /// A fresh NEXT-WORD ghost reduced to a single character ("m" after "envie
    /// de ") is noise — one letter conveys no intent and is almost always a
    /// streaming stub whose continuation got gated out (base-model junk, or a
    /// corpus bias that flips only the first token). Skip it and wait for ≥2
    /// chars; nothing beats a lone letter.
    ///
    /// Fires ONLY when the caret sits at a word boundary — `userTail` is empty
    /// or ends in a non-alphanumeric char (space/punctuation). A MID-WORD
    /// completion that finishes the current word ("Bonjou" → "r") ends in a
    /// letter, so this never suppresses it. The ghost's leading space (next-word
    /// continuation marker) is ignored when measuring length.
    static func isNextWordStub(userTail: String, ghost: String) -> Bool {
        // The ghost begins a NEW word when EITHER the caret sits at a word
        // boundary (userTail empty / ends in space or punctuation) OR the ghost
        // itself starts with a space (a next-word continuation after a complete
        // word: "envie" → " manger"). A mid-word completion ("Bonjou" → "r")
        // satisfies neither and is exempt.
        let caretAtWordBoundary = userTail.last.map {
            !($0.isLetter || $0.isNumber)
        } ?? true
        let ghostStartsNewWord = caretAtWordBoundary || ghost.first == " "
        guard ghostStartsNewWord else { return false }
        return ghost.drop(while: { $0 == " " }).count < 2
    }

    /// A MID-WORD ghost reduced to a single character ("opé" → "r", "dp" → "n")
    /// is noise: it's the LLM's first streamed token shown before the rest
    /// arrives, or a confused short output on a word the base model doesn't
    /// recognise (typos, abbreviations). One letter spliced mid-word is
    /// unreadable as intent and flickers. Fires when the caret sits INSIDE a word
    /// (`userTail` ends in a letter/number) AND the ghost is a single,
    /// non-space-led char — i.e. it continues the current word but says almost
    /// nothing yet.
    ///
    /// Complement of `isNextWordStub` (which covers the word-boundary case). The
    /// accepted cost: a genuine 1-letter completion ("Bonjou" → "r") is withheld
    /// until the stream produces ≥2 chars — a lone mid-word letter is always
    /// visual noise, never a useful ghost, so the trade is worth it.
    static func isMidWordStub(userTail: String, ghost: String) -> Bool {
        let caretMidWord = userTail.last.map { $0.isLetter || $0.isNumber } ?? false
        guard caretMidWord else { return false }
        // Next-word ghosts (leading space) are isNextWordStub's job.
        guard ghost.first != " " else { return false }
        return ghost.count < 2
    }

    /// Phase 4 — cancel avec discriminator pour la classification grid.
    /// `cancel(reason:)` permet aux call-sites externes (AppDelegate handleKey
    /// Esc → `.dismissedByEsc`) de différencier les raisons de fin de vie.
    /// Le default `.focusChange` est silencieux (D-09) — utilisé pour les
    /// cancellations internes (live-consume, Tab accept, typo, swap).
    func cancel(reason: LifecycleEndReason) {
        policy.endLifecycle(reason: reason)
        // Phase 4 — lifecycle owned by GenerationPlanner. `planner.cancel()`
        // cancelle la Task in-flight + bump le counter (invalide les onChunk
        // updates par closure isCurrent(token) check).
        planner.cancel()
        suggestion = ""
        predictedForPrefix = ""
        suggestionSource = .none
        policy.reset()
        // IMPORTANT: cache is preserved. `cancel()` is called from many paths
        // that are NOT context breaks — live-consume promotion, Tab full/
        // partial accept, typo flag, hide-on-typo. Clearing the cache there
        // would defeat undo-as-ghost. True context breaks (model swap, Esc
        // dismissal, app disabled, focus → different bundle) must call
        // `clearPredictCache()` explicitly at the call site.
    }

    /// Backward-compat shim — defaults to `.focusChange` (silent classification
    /// category D-09). Call-sites internes (live-consume, partial accept) gardent
    /// la signature originale. Les call-sites externes qui veulent discriminer
    /// (Esc dismiss) doivent appeler `cancel(reason:)` directement.
    func cancel() {
        cancel(reason: .focusChange)
    }
}
