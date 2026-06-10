import Accelerate
import CLlama
import Foundation
import SouffleuseLog

// MARK: - BeamGhostEngine
//
// Moteur de ghost EXPÉRIMENTAL « façon Cotypist » — recherche multi-séquences
// déterministe, classée en log-probabilité, élaguée top-K. C'est un SPIKE de
// recherche : il tourne À CÔTÉ du `LlamaEngine` greedy existant, jamais à sa
// place. Tout est gaté par `SOUFFLEUSE_BEAM` au point d'appel (l'éval / un
// éventuel call-site `ModelRuntime`) — ce fichier n'est JAMAIS atteint quand le
// flag est absent, donc le pipeline shippé reste byte-identique.
//
// POURQUOI un moteur séparé plutôt qu'un chemin sur `LlamaEngine` :
//  1. Le beam a besoin d'un contexte llama.cpp avec `n_seq_max ≥ K+1` (≥10),
//     alors que le `LlamaEngine` de prod crée son contexte sans le fixer
//     (mono-séquence). Isoler le contexte évite toute interférence avec le KV
//     de la passe greedy et garantit le « byte-identical flag-off ».
//  2. La logique (fork KV, batch multi-seq explicite, ranking cumulatif,
//     contrainte requiredPrefix) est assez différente du `generate()` token-par-
//     token pour mériter son propre type — convention maison « un type = un
//     concern ».
//
// Reconstruction Cotypist (docs/cotypist-ghost-generation-reconstruction.html) :
//   maxSearchWidth = 9 · maxResultWidth = 9 · minBranchProbability = 0.05 ·
//   relativeCutoff = 1e-10 · métrique de pruning = totalLogprob · pas de
//   sampling aléatoire · mid-word contraint par requiredPrefix.
//
// FIDÉLITÉ vs APPROXIMATION (honnêteté) :
//  - Le KV est PARTAGÉ : le prompt est préfillé UNE fois en séquence 0, puis
//    chaque branche est un `llama_memory_seq_cp` de son parent (copie du
//    préfixe commun, pas une re-décode). C'est le cœur « single shared context,
//    K candidate sequences » de la RE.
//  - L'exposant du poids de position (`pow(tokenCount, exponent)`) est INCONNU
//    dans la RE → exposé en knob, défaut 0.0 (= somme pure des log-probs).

/// Un knob de réglage du beam, tiré soit de l'environnement (override d'éval)
/// soit des défauts Cotypist reconstruits. Tous `static` sur le type, style
/// maison. `Sendable` trivial (que des valeurs).
public struct BeamConfig: Sendable {
    /// Nombre maximal de séquences candidates vivantes simultanément (Cotypist
    /// `maxSearchWidth`). Borne aussi `n_seq_max` du contexte (+1 pour la seq 0
    /// du prompt partagé).
    public var maxSearchWidth: Int
    /// Largeur conservée après élagage top-K (Cotypist `maxResultWidth`).
    public var maxResultWidth: Int
    /// Probabilité softmax minimale d'un token pour OUVRIR une branche dessus
    /// (Cotypist `minBranchProbability`). Sous ce seuil, le token n'engendre pas
    /// de candidat — c'est ce qui borne le fan-out par étape.
    public var minBranchProbability: Double
    /// Coupe relative : un candidat dont le score est en-dessous de
    /// `meilleurScore + log(relativeCutoff)` est jeté même s'il survit au top-K.
    /// (Cotypist `relativeCutoff = 1e-10`.)
    public var relativeCutoff: Double
    /// Exposant du poids de position dans le score : `score = totalLogprob /
    /// pow(tokenCount, exponent)`. La RE ne connaît PAS sa valeur exacte →
    /// défaut 0.0 (= somme pure, `pow(_,0)=1`), exposé pour A/B. > 0 favorise
    /// les continuations longues (normalise par la longueur), < 0 les courtes.
    public var positionExponent: Double
    /// Budget dur de tokens générés par candidat (esprit du long-ghost ~14).
    public var maxTokens: Int
    /// Budget dur de mots du ghost retourné (esprit du long-ghost ~4 mots).
    public var maxWords: Int

    public static let cotypistDefault = BeamConfig(
        maxSearchWidth: 9,
        maxResultWidth: 9,
        minBranchProbability: 0.05,
        relativeCutoff: 1e-10,
        positionExponent: 0.0,
        maxTokens: 14,
        maxWords: 4
    )

    /// Config du **cœur de génération de prod** (`SOUFFLEUSE_BEAM_CORE`).
    /// K=2 · maxTokens=12 · maxWords=3 — mesuré par SouffleuseParityEval
    /// (PARITY-FINDINGS.md §5, 1087 frappes, après le fix de routage mid-mot) :
    ///
    ///   | config            | lat moy/p50 | KTC ≤1/≤3 | jamais | word-accept |
    ///   | K=3·tok14·mots4   | 216 / 209   | 55 / 85 % | 7 %    | 52 %        |
    ///   | K=2·tok12·mots3   | 125 / 114   | 58 / 82 % | 8 %    | 51 %        |
    ///
    /// → latence −42 % pour −3,5 % relatif de KTC≤3 et −1,9 % de word-accept
    /// (dans le budget « ≤5 % de validité ») ; le hit à 1 lettre MONTE même de
    /// 3 pts (moins de branches = moins de candidats exotiques en tête). La
    /// contrainte `requiredPrefix` fait l'essentiel du travail, K n'affine que
    /// le ranking (sweep : K=1 70 %, K=2 72 %, K=3 75 % en one-shot). On garde
    /// `cotypistDefault` (K=9) INTACT comme reconstruction fidèle + baseline des
    /// evals ; ce profil-ci est celui que `ModelRuntime` charge en prod.
    public static let ghostCoreDefault = BeamConfig(
        maxSearchWidth: 2,
        maxResultWidth: 2,
        minBranchProbability: 0.05,
        relativeCutoff: 1e-10,
        // Normalisation par longueur. À 0.0 le score = somme PURE des log-probs →
        // chaque token ajouté rend le score plus négatif → le ranking pénalise
        // mécaniquement les continuations longues (le beam préfère le court/tronqué).
        // L'eval ne mesurait que le hit@1 du MOT (court, insensible) ; la suite
        // 2-3 mots a besoin de length-norm pour être classée équitablement. 0.7 =
        // milieu classique (façon GNMT). Override live via `SOUFFLEUSE_BEAM_EXP`.
        positionExponent: 0.7,
        maxTokens: 12,
        maxWords: 3
    )

    /// Config du cœur de prod avec overrides d'ENVIRONNEMENT (A/B sans rebuild) :
    /// `SOUFFLEUSE_BEAM_EXP` (Double, length-norm), `SOUFFLEUSE_BEAM_K` (Int),
    /// `SOUFFLEUSE_BEAM_MAXTOK` (Int, budget tokens/candidat) et
    /// `SOUFFLEUSE_BEAM_MAXWORDS` (Int, cap mots du ghost). Part de
    /// `ghostCoreDefault`. Lu une fois par `ModelRuntime` au lancement.
    public static func ghostCore() -> BeamConfig {
        var c = ghostCoreDefault
        let env = ProcessInfo.processInfo.environment
        if let s = env["SOUFFLEUSE_BEAM_EXP"], let v = Double(s) { c.positionExponent = v }
        if let s = env["SOUFFLEUSE_BEAM_K"], let v = Int(s), v > 0 { c.maxSearchWidth = v; c.maxResultWidth = v }
        if let s = env["SOUFFLEUSE_BEAM_MAXTOK"], let v = Int(s), v > 0 { c.maxTokens = v }
        if let s = env["SOUFFLEUSE_BEAM_MAXWORDS"], let v = Int(s), v > 0 { c.maxWords = v }
        return c
    }

    public init(maxSearchWidth: Int, maxResultWidth: Int, minBranchProbability: Double,
                relativeCutoff: Double, positionExponent: Double, maxTokens: Int, maxWords: Int) {
        self.maxSearchWidth = maxSearchWidth
        self.maxResultWidth = maxResultWidth
        self.minBranchProbability = minBranchProbability
        self.relativeCutoff = relativeCutoff
        self.positionExponent = positionExponent
        self.maxTokens = maxTokens
        self.maxWords = maxWords
    }

    /// Construit la config en lisant d'éventuels overrides d'environnement
    /// (utilisé par l'éval pour balayer l'exposant inconnu sans recompiler).
    /// `SOUFFLEUSE_BEAM_EXP` (Double), `SOUFFLEUSE_BEAM_K` (Int).
    public static func fromEnvironment() -> BeamConfig {
        var c = cotypistDefault
        let env = ProcessInfo.processInfo.environment
        if let s = env["SOUFFLEUSE_BEAM_EXP"], let v = Double(s) { c.positionExponent = v }
        if let s = env["SOUFFLEUSE_BEAM_K"], let v = Int(s), v > 0 { c.maxSearchWidth = v; c.maxResultWidth = v }
        if let s = env["SOUFFLEUSE_BEAM_MAXTOK"], let v = Int(s), v > 0 { c.maxTokens = v }
        return c
    }
}

/// Un candidat retourné par le beam : le suffixe non-tapé (le ghost), son score
/// final et la log-prob cumulée brute (pour l'éval/observabilité). `Sendable`.
public struct BeamCandidate: Sendable {
    /// Le texte du ghost : pour un caret mid-word, UNIQUEMENT le suffixe au-delà
    /// du fragment déjà tapé (« conf » → « irmer le rendez-vous »).
    public let ghost: String
    /// Le score final classé (totalLogprob pondéré par la position).
    public let score: Double
    /// La log-prob cumulée brute (somme des log P par token), avant pondération.
    public let totalLogprob: Double
    /// Nombre de tokens générés par ce candidat (pour comprendre le ranking).
    public let tokenCount: Int

    public init(ghost: String, score: Double, totalLogprob: Double, tokenCount: Int) {
        self.ghost = ghost
        self.score = score
        self.totalLogprob = totalLogprob
        self.tokenCount = tokenCount
    }
}

/// Résultat complet d'un appel beam : le meilleur ghost + les alternatives
/// classées (regroupables par préfixe par l'appelant pour réutiliser une
/// branche à la frappe suivante — « un ghost, plusieurs futurs en réserve »).
public struct BeamResult: Sendable {
    public let best: BeamCandidate?
    /// Tous les candidats finalisés, triés par score décroissant (best inclus).
    public let candidates: [BeamCandidate]
    /// Latence totale de l'appel en millisecondes (observabilité d'éval).
    public let elapsedMillis: Int
    /// Observabilité du prefix-cache KV : taille du prompt en TOKENS et part
    /// RÉUTILISÉE depuis le cache (LCP avec l'appel précédent). Un appel « tout
    /// froid » a `reusedPrefixTokens ≈ 0` — c'est lui qui paie la re-prefill
    /// complète. 0/0 sur les early-returns (prompt vide, échec).
    public let promptTokenCount: Int
    public let reusedPrefixTokens: Int
    /// Décomposition INTERNE du coût (mesure pure, comportement intouché) :
    /// `prefillMillis` = le `llama_decode` du suffixe de prompt nouveau ;
    /// `decodeMillis` = la boucle pas-à-pas (decode multi-seq + scan vocab +
    /// expansion). Le reste d'`elapsedMillis` = tokenisation/healing/ranking.
    /// Sert à départager « le seed est lent parce que prefill » vs « parce que
    /// pas de décodage » (effet taille de contexte). 0 sur les early-returns.
    public let prefillMillis: Int
    public let decodeMillis: Int
    public init(best: BeamCandidate?, candidates: [BeamCandidate], elapsedMillis: Int,
                promptTokenCount: Int = 0, reusedPrefixTokens: Int = 0,
                prefillMillis: Int = 0, decodeMillis: Int = 0) {
        self.best = best
        self.candidates = candidates
        self.elapsedMillis = elapsedMillis
        self.promptTokenCount = promptTokenCount
        self.reusedPrefixTokens = reusedPrefixTokens
        self.prefillMillis = prefillMillis
        self.decodeMillis = decodeMillis
    }
}

// MARK: - Réutilisation de branche (KV reuse à la frappe suivante)

/// Nature d'un pas de frappe servi par `advance(typedChar:)` — l'observable
/// central de l'éval amortie. C'est le « coût réel » du beam en usage vivant.
public enum AdvanceKind: Sendable {
    /// HIT : ≥1 branche de la réserve avait ce char en tête de son suffixe ghost.
    /// On a juste avancé le pointeur de consommation — AUCUN `llama_decode`. Le
    /// nouveau ghost est le reste du suffixe déjà calculé. C'est le cas Cotypist
    /// « la frappe suivante recycle une branche ».
    case hit
    /// REFILL : les survivants ont matché MAIS leur suffixe pré-calculé est devenu
    /// trop court (l'utilisateur a consommé presque tout le KV d'avance). On a
    /// re-décodé quelques tokens — SEULEMENT sur les survivants, SEULEMENT en
    /// profondeur — pour reconstituer la réserve. Bien moins cher qu'un beam froid.
    case refill
    /// MISS : aucune branche compatible avec le char tapé (vraie divergence) →
    /// re-beam complet depuis le nouveau préfixe. C'est le coût froid.
    case miss
}

/// Résultat d'un pas de frappe amorti : le ghost à afficher, la nature du pas
/// (hit/refill/miss) et la latence. Sert l'éval amortie ; `Sendable` trivial.
public struct AdvanceResult: Sendable {
    public let ghost: String
    public let kind: AdvanceKind
    public let elapsedMillis: Int
    /// Nombre de branches survivantes après le pas (santé de la réserve).
    public let survivors: Int
    public init(ghost: String, kind: AdvanceKind, elapsedMillis: Int, survivors: Int) {
        self.ghost = ghost
        self.kind = kind
        self.elapsedMillis = elapsedMillis
        self.survivors = survivors
    }
}

/// Moteur de ghost multi-séquences. `actor` (comme `LlamaEngine`) : les
/// pointeurs llama.cpp ne franchissent jamais la frontière d'isolation.
public actor BeamGhostEngine {
    /// Handles opaques modèle + contexte. `@unchecked Sendable` est sûr : ces
    /// pointeurs ne sont touchés QUE depuis le contexte d'exécution sérialisé de
    /// l'actor.
    private struct Handles: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let nCtx: Int32
        let nVocab: Int32
        let nSeqMax: Int32
        /// Le moteur POSSÈDE-t-il `model` (donc doit le `llama_model_free`) ? Faux
        /// quand le modèle est EMPRUNTÉ à `LlamaEngine` (poids partagés) : on ne
        /// libère alors QUE le contexte ; le prêteur free le modèle.
        let ownsModel: Bool
    }

    private var handles: Handles?
    private var config: BeamConfig

    /// La RÉSERVE : les branches candidates laissées VIVANTES après un beam, KV
    /// inclus. Chacune porte un seqId KV non recyclé (préfixe partagé + ses tokens
    /// propres déjà décodés) et un pointeur de consommation `consumed` indiquant
    /// combien de chars de son suffixe l'utilisateur a déjà tapés. À la frappe
    /// suivante, on matche le char tapé contre le 1ᵉʳ char non-consommé de chaque
    /// réserve : les compatibles avancent leur pointeur (HIT, zéro decode), les
    /// divergentes voient leur KV effacé. C'est « plusieurs futurs en réserve,
    /// recyclés quand l'utilisateur continue de taper » (RE stage 04 / 08).
    private var reserve: [ReservedBranch] = []
    /// Contexte (prompt + requiredPrefix) auquel la réserve est attachée — sert à
    /// re-beamer proprement sur un MISS (on connaît le prompt d'origine + le texte
    /// déjà accepté implicitement par les frappes successives).
    private var reservePrompt: String = ""
    private var reserveTypedSoFar: String = ""

    public init(config: BeamConfig = .cotypistDefault) {
        self.config = config
    }

    public var isReady: Bool { handles != nil }

    // MARK: - Lifecycle

    /// Charge un GGUF en créant un contexte DÉDIÉ avec `n_seq_max = K + 1` — le
    /// +1 est la séquence 0 qui porte le prompt partagé ; les K autres sont les
    /// branches forkées. C'est ce qui autorise les `llama_memory_seq_cp` /
    /// batches multi-seq sans toucher au contexte mono-séquence de prod.
    @discardableResult
    public func load(modelPath path: String, contextTokens: UInt32 = 4096) -> Bool {
        _ = BeamGhostEngine.backendOnce
        unload()
        guard FileManager.default.fileExists(atPath: path) else {
            Log.error(.predictor, "beam_load_failed")
            return false
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            Log.error(.predictor, "beam_load_failed")
            return false
        }
        // On possède ce modèle (chargé ici) → ownsModel: true.
        return makeContext(model: model, contextTokens: contextTokens, ownsModel: true)
    }

    /// Charge en EMPRUNTANT un `llama_model` déjà résident (typiquement celui de
    /// `LlamaEngine`, via `borrowModel()`). Ne charge PAS de poids : crée seulement
    /// le contexte multi-séquences (`n_seq_max = K+1`) sur le modèle partagé →
    /// surcoût RAM = juste le KV (quelques Mo), pas un 2ᵉ Go de poids. `ownsModel:
    /// false` ⇒ `unload`/`deinit` ne libèrent QUE le contexte. INVARIANT d'ordre :
    /// l'appelant doit `unload()` CE moteur AVANT de libérer/recharger le modèle
    /// prêteur (sinon ce contexte référencerait un modèle libéré). Géré par
    /// `ModelRuntime` (beam déchargé avant tout reload de `LlamaEngine`).
    @discardableResult
    public func load(borrowedModel: BorrowedModel, contextTokens: UInt32 = 4096) -> Bool {
        _ = BeamGhostEngine.backendOnce
        unload()
        return makeContext(model: borrowedModel.model, contextTokens: contextTokens, ownsModel: false)
    }

    /// Crée le contexte multi-séquences dédié sur `model` et publie les `Handles`.
    /// Partagé par les deux `load` (modèle possédé vs emprunté). En cas d'échec,
    /// ne libère le modèle QUE si on le possède (`ownsModel`).
    private func makeContext(model: OpaquePointer, contextTokens: UInt32, ownsModel: Bool) -> Bool {
        let nSeqMax = Int32(config.maxSearchWidth + 1)
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextTokens
        ctxParams.n_batch = contextTokens
        ctxParams.n_seq_max = UInt32(nSeqMax)
        // Les branches partagent un long préfixe (le prompt) : le buffer KV
        // unifié est le bon choix de perf ici (cf. note llama.h sur kv_unified
        // et le partage de préfixe). On garde le défaut (unifié).
        let cores = ProcessInfo.processInfo.activeProcessorCount
        ctxParams.n_threads = Int32(max(1, cores - 1))
        ctxParams.n_threads_batch = Int32(max(1, cores - 1))

        guard let context = llama_init_from_model(model, ctxParams) else {
            if ownsModel { llama_model_free(model) }
            Log.error(.predictor, "beam_load_failed"); return false
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            if ownsModel { llama_model_free(model) }
            Log.error(.predictor, "beam_load_failed"); return false
        }

        handles = Handles(
            model: model, context: context, vocab: vocab,
            nCtx: Int32(llama_n_ctx(context)),
            nVocab: llama_vocab_n_tokens(vocab),
            nSeqMax: nSeqMax,
            ownsModel: ownsModel
        )
        surfacePieceCache = nil   // nouveau vocab → cache surface à rebâtir
        firstCharIndex = nil      // idem pour l'index 1er-char
        cachedPromptTokens = []   // KV neuf → pas de préfixe réutilisable
        Log.info(.predictor, "beam_loaded")
        return true
    }

    public func unload() {
        if let h = handles {
            llama_free(h.context)
            if h.ownsModel { llama_model_free(h.model) }
        }
        handles = nil
        cachedPromptTokens = []
    }

    deinit {
        if let h = handles {
            llama_free(h.context)
            if h.ownsModel { llama_model_free(h.model) }
        }
    }

    private static let backendOnce: Void = {
        llama_log_set({ _, _, _ in }, nil)
        ggml_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    // MARK: - Tokenisation / pièces (mêmes helpers que LlamaEngine, repris ici)

    private func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        guard let h = handles else { return [] }
        let utf8 = Array(text.utf8)
        if utf8.isEmpty && !addSpecial { return [] }
        let capacity = utf8.count + 16
        var tokens = [Int32](repeating: 0, count: capacity)
        let n = utf8.withUnsafeBufferPointer { textPtr -> Int32 in
            tokens.withUnsafeMutableBufferPointer { tokPtr in
                llama_tokenize(h.vocab,
                    textPtr.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: utf8.count) { $0 } },
                    Int32(utf8.count), tokPtr.baseAddress, Int32(capacity), addSpecial, true)
            }
        }
        if n < 0 {
            let needed = Int(-n)
            tokens = [Int32](repeating: 0, count: needed)
            _ = utf8.withUnsafeBufferPointer { textPtr in
                tokens.withUnsafeMutableBufferPointer { tokPtr in
                    llama_tokenize(h.vocab,
                        textPtr.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: utf8.count) { $0 } },
                        Int32(utf8.count), tokPtr.baseAddress, Int32(needed), addSpecial, true)
                }
            }
            return tokens
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// Pièce UTF-8 BRUTE d'un token (avec son éventuelle métaspace → espace).
    private func piece(_ token: Int32) -> String {
        guard let h = handles else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(h.vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            let needed = Int(-n)
            buf = [CChar](repeating: 0, count: needed)
            let n2 = llama_token_to_piece(h.vocab, token, &buf, Int32(needed), 0, false)
            guard n2 > 0 else { return "" }
            return String(decoding: buf[0..<Int(n2)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Pièce « surface » : la métaspace SentencePiece `▁` (U+2581) est rendue
    /// par llama.cpp comme un espace littéral en tête. C'est la SURFACE réelle
    /// que le token ajoute à la chaîne visible — utilisée pour matcher le
    /// requiredPrefix mid-word (où un espace en tête signifie « nouveau mot »,
    /// donc INCOMPATIBLE avec un préfixe de mot en cours).
    private func surface(_ token: Int32) -> String {
        piece(token).replacingOccurrences(of: "\u{2581}", with: " ")
    }

    // MARK: - Recherche beam

    /// État interne d'une branche candidate vivante. Une branche = une séquence
    /// KV (id `seqId`) qui porte le préfixe partagé + ses tokens propres.
    private struct Branch {
        var seqId: Int32             // seqId KV PORTANT le préfixe de cette branche (assigné au pruning)
        var parentSeqId: Int32       // seqId du parent dont on dérive (pour le fork KV au pruning)
        var tokens: [Int32]          // tokens générés par CETTE branche (hors prompt)
        var totalLogprob: Double     // Σ log P(tokenᵢ | …)
        var surfaceText: String      // concat des surfaces des tokens (= texte brut produit)
        /// Reste du préfixe obligatoire mid-word encore à satisfaire. Vide quand
        /// le fragment tapé est entièrement consommé (le ghost commence après).
        var remainingRequiredPrefix: String
        /// Longueur (en chars de surface) du requiredPrefix initial — pour
        /// retrancher la partie déjà-tapée du ghost final.
        var requiredPrefixConsumed: Int
        var finished: Bool

        /// Score classé : log-prob cumulée pondérée par la position. Avec
        /// `exponent = 0` → somme pure (`pow(n,0) = 1`).
        func score(positionExponent: Double) -> Double {
            let n = max(1, tokens.count)
            let weight = pow(Double(n), positionExponent)
            return totalLogprob / weight
        }
    }

    /// Lance la recherche beam sur `prompt`. `requiredPrefix` (le fragment de mot
    /// déjà tapé en mid-word, ex. « conf ») contraint DUREMENT le décodage : un
    /// token incompatible tue sa branche ; seul le suffixe non-tapé devient le
    /// ghost. Vide ⇒ décodage libre après-espace.
    ///
    /// Déterministe (aucun sampling aléatoire) : à chaque étape on calcule la
    /// log-prob softmax par token, on ouvre des branches sur les tokens de
    /// probabilité ≥ `minBranchProbability`, on accumule, puis on élague top-K.
    public func generateBeam(prompt: String, requiredPrefix: String = "") -> BeamResult {
        generateBeam(prompt: prompt, requiredPrefix: requiredPrefix, captureReserve: false)
    }

    /// Variante interne avec capture de réserve. Quand `captureReserve == true`,
    /// on NE recycle PAS le KV des branches finales : on les conserve (seqId +
    /// tokens + suffixe ghost) dans `self.reserve` pour que la frappe suivante
    /// recycle une branche sans re-décoder. C'est le cœur du « KV branch reuse ».
    private func generateBeam(prompt: String, requiredPrefix: String, captureReserve: Bool) -> BeamResult {
        let start = Date()
        guard let h = handles else { return BeamResult(best: nil, candidates: [], elapsedMillis: 0) }

        var promptTokens = tokenize(prompt, addSpecial: true)
        guard !promptTokens.isEmpty else { return BeamResult(best: nil, candidates: [], elapsedMillis: 0) }
        // Garde fenêtre : on borne le prompt pour laisser de la place aux tokens
        // générés sur CHAQUE séquence.
        let maxPrompt = Int(h.nCtx) - config.maxTokens - 4
        if maxPrompt > 0, promptTokens.count > maxPrompt {
            promptTokens = Array(promptTokens.suffix(maxPrompt))
        }

        // ── Healing du prompt (mid-mot) ──────────────────────────────────────
        // Le `requiredPrefix` (ex. « conf ») est DÉJÀ présent en queue de prompt :
        // si on préfille tel quel, le modèle continue APRÈS « conf » et ne ré-émet
        // jamais le mot — la contrainte requiredPrefix ne matche alors aucun token.
        // Comme la passe greedy (`LlamaSampling.healPrefix`), on POP les tokens de
        // queue qui couvrent le fragment tapé, pour re-décoder le mot DEPUIS sa
        // frontière propre sous la contrainte. `requiredPrefix` reste le fragment
        // à re-satisfaire ; seul le suffixe au-delà devient le ghost.
        var rootRequired = requiredPrefix
        if !requiredPrefix.isEmpty, promptTokens.count > 1 {
            var acc = ""
            var popCount = 0
            let maxPop = min(promptTokens.count - 1, 8)
            while popCount < maxPop {
                let p = surface(promptTokens[promptTokens.count - 1 - popCount])
                acc = p + acc
                popCount += 1
                if acc.hasSuffix(requiredPrefix) || acc.count >= requiredPrefix.count { break }
            }
            if popCount > 0, acc.hasSuffix(requiredPrefix) {
                promptTokens.removeLast(popCount)
            } else {
                // Boundary inattendue : on ne peut pas healer proprement → on
                // renonce à la contrainte (décodage libre) plutôt que de tout tuer.
                rootRequired = ""
            }
        }

        let mem = llama_get_memory(h.context)
        // ── Prefix-caching KV du prompt (seq 0) entre deux appels ─────────────
        // Entre deux frappes, le prompt (contexte prose + texte avant curseur) ne
        // diffère que par sa QUEUE : re-préfiller l'intégralité coûtait ~110 ms
        // par frappe avec un ctxPrefix réaliste (mesuré PARITY_LONGCTX=1). On
        // garde le KV de la seq 0, on coupe à partir du point de divergence
        // (plus long préfixe commun en TOKENS — la retokenisation de fin de mot
        // rend la comparaison char-à-char invalide) et on ne décode QUE le
        // suffixe nouveau. Toujours ≥ 1 token re-décodé : les logits next-token
        // doivent être frais (même garde que `KVCacheHolder` côté greedy).
        // Les séquences de branches (1..K) d'un appel précédent sont effacées ;
        // les tokens de branche logés en seq 0 (1ᵉʳ survivant « en place ») le
        // sont aussi par la coupe (positions ≥ ancien promptLen ≥ lcp).
        // Toute réserve antérieure devient INVALIDE ici : on efface les séquences
        // de branches juste en dessous — un `advance` ultérieur sur ces seqIds
        // refillerait dans du KV vide. `buildReserve` la reconstruit en sortie
        // quand `captureReserve` est posé.
        reserve = []
        var lcp = 0
        let maxShared = min(cachedPromptTokens.count, promptTokens.count - 1)
        while lcp < maxShared, cachedPromptTokens[lcp] == promptTokens[lcp] { lcp += 1 }
        if let mem {
            for sid in 1..<h.nSeqMax { llama_memory_seq_rm(mem, sid, -1, -1) }
            llama_memory_seq_rm(mem, 0, Int32(lcp), -1)
        }

        // ── Préfill du SUFFIXE nouveau en séquence 0 (le préfixe partagé) ─────
        let prefillStart = Date()
        guard prefill(suffix: Array(promptTokens[lcp...]), fromPos: Int32(lcp)) else {
            cachedPromptTokens = []
            if let mem { llama_memory_seq_rm(mem, -1, -1, -1) }   // KV partiel → repartir propre
            return BeamResult(best: nil, candidates: [], elapsedMillis: Int(Date().timeIntervalSince(start) * 1000))
        }
        let prefillMs = Int(Date().timeIntervalSince(prefillStart) * 1000)
        cachedPromptTokens = promptTokens
        let promptLen = Int32(promptTokens.count)

        // Branche racine : seqId 0, aucun token propre, score 0, requiredPrefix
        // complet. La position de départ pour le prochain token est `promptLen`.
        var live: [Branch] = [Branch(
            seqId: 0, parentSeqId: 0, tokens: [], totalLogprob: 0, surfaceText: "",
            remainingRequiredPrefix: rootRequired,
            requiredPrefixConsumed: 0, finished: false
        )]
        var finished: [Branch] = []
        let nVocab = Int(h.nVocab)

        // ── Boucle de décodage pas-à-pas ─────────────────────────────────────
        // À chaque étape : on décode UN batch multi-séquences (un token « dernier »
        // par branche vivante), on lit les logits par séquence, on étend.
        let decodeStart = Date()
        for _ in 0..<config.maxTokens {
            if live.isEmpty { break }
            // Cancel-on-keystroke À L'INTÉRIEUR du beam. Sans ce check, un beam
            // périmé courait jusqu'au bout de ses ~12 pas de décodage pendant que
            // la frappe suivante SÉRIALISAIT derrière l'actor — mesuré en prod
            // (trace de latence) : p50 713 ms / p95 2 s par génération vs ~240 ms
            // au banc, et 742 ms d'attente predict→gen au p95. On rend la main au
            // 1ᵉʳ pas suivant l'annulation : les seqs de branches sont recyclées
            // au prochain appel et le prefix-cache (seq 0, `cachedPromptTokens`)
            // reste valide — état cohérent, le caller jette le résultat partiel.
            if Task.isCancelled { break }

            // Décode la position courante de chaque branche vivante et récupère,
            // pour chacune, l'indice logits où lire sa distribution next-token.
            guard let logitRows = decodeStep(branches: live, promptLen: promptLen, mem: mem) else { break }

            // Expansion : pour chaque branche, softmax → tokens candidats au-dessus
            // du seuil de branche → nouvelles branches (filtrées par requiredPrefix).
            var expanded: [Branch] = []
            expanded.reserveCapacity(live.count * 3)

            for (bi, branch) in live.enumerated() {
                let logits = logitRows[bi]
                // ── Seuil de branche vs contrainte requiredPrefix ───────────────
                // CRUCIAL : tant que le préfixe obligatoire mid-mot n'est pas
                // consommé, le `minBranchProbability` (0.05) NE doit PAS pré-
                // élaguer, car la seule continuation compatible (« command » →
                // « commande ») peut avoir une proba < 5 % parmi TOUS les mots
                // possibles. On prend alors les meilleurs tokens COMPATIBLES par
                // log-prob brute (la contrainte REMPLACE le seuil de proba pendant
                // la consommation du préfixe). Une fois le préfixe épuisé, on
                // revient au seuil `minBranchProbability` standard.
                let next: [NextToken]
                if branch.remainingRequiredPrefix.isEmpty {
                    next = topNextTokens(logits: logits, nVocab: nVocab,
                                         minProb: config.minBranchProbability)
                } else {
                    next = topCompatibleTokens(logits: logits, nVocab: nVocab,
                                               required: branch.remainingRequiredPrefix,
                                               firstToken: branch.requiredPrefixConsumed == 0)
                }
                if next.isEmpty {
                    // Aucun token assez probable : la branche s'arrête ici (on la
                    // finalise telle quelle si elle a déjà du texte valide).
                    if !branch.tokens.isEmpty && branch.remainingRequiredPrefix.isEmpty {
                        var b = branch; b.finished = true; finished.append(b)
                    }
                    continue
                }
                for cand in next {
                    guard let child = extend(branch: branch, tokenId: cand.tokenId,
                                             logProb: cand.logProb) else {
                        continue   // incompatible avec le requiredPrefix → branche tuée
                    }
                    expanded.append(child)
                }
            }

            // ── Élagage top-K déterministe ───────────────────────────────────
            // Tri par score décroissant ; seuil = score du K-ième ; on garde
            // score ≥ seuil. Puis coupe relative (relativeCutoff).
            expanded.sort { $0.score(positionExponent: config.positionExponent)
                          > $1.score(positionExponent: config.positionExponent) }

            // Sépare les terminées (frontière de phrase / budget mots) des
            // VIVANTES candidates. Les finies n'ont pas besoin de seqId KV (elles
            // ne re-décodent plus) — leur texte est déjà figé.
            var stopping: [Branch] = []
            var continuing: [Branch] = []
            for var b in expanded {
                if shouldStop(branch: b) {
                    b.finished = true
                    stopping.append(b)
                } else {
                    continuing.append(b)
                }
            }

            // Élague le top-K parmi les VIVANTES (les finies sont déjà figées et
            // toutes conservées comme candidats résultat).
            var nextLive = pruneTopK(continuing)

            // ── Assignation paresseuse des seqIds + fork KV ──────────────────
            // Pour chaque seqId parente, le PREMIER survivant la réutilise en
            // place (pas de copie) ; les survivants suivants forkent une seqId
            // fraîche du pool via `seq_cp(parent → fresh)`. Une seqId parente non
            // réutilisée par aucun survivant est effacée et rendue au pool.
            assignSeqIds(survivors: &nextLive, parentsAlive: live, mem: mem)

            finished.append(contentsOf: stopping)
            live = nextLive
        }
        let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)

        // Finalise les branches encore vivantes au budget épuisé (suffixe valide).
        for var b in live where b.remainingRequiredPrefix.isEmpty && !b.tokens.isEmpty {
            b.finished = true
            finished.append(b)
        }

        // ── Capture de la réserve (KV reuse) ─────────────────────────────────
        // On retient DEUX familles de candidats :
        //  1. Les branches FINALES `live` : KV encore VIVANT, seqId propre (jamais
        //     recyclé après le dernier `assignSeqIds`). Réutilisables ET refillables
        //     (on peut re-décoder en profondeur dans leur séquence).
        //  2. Les branches ARRÊTÉES (frontière de phrase / budget mots) : leur
        //     suffixe est COMPLET et FIGÉ, donc affichable par simple avance de
        //     pointeur SANS aucun KV (`seqId = -1`). Ce sont souvent les MEILLEURS
        //     candidats (le ghost « propre » se termine sur un point) — les exclure
        //     vidait la réserve de ses futurs les plus probables (cause des faux
        //     MISS). On les conserve gelés.
        // On NE fait PAS le `seq_rm(-1)` qui ouvrirait le prochain beam : on garde
        // le KV des branches vivantes pour le recycler à la frappe suivante.
        if captureReserve {
            buildReserve(live: live, finished: finished,
                         rootRequired: rootRequired, prompt: prompt)
        }

        // ── Construction du résultat ─────────────────────────────────────────
        let scored = finished
            .filter { $0.remainingRequiredPrefix.isEmpty }
            .map { b -> BeamCandidate in
                BeamCandidate(
                    ghost: ghostText(of: b, requiredPrefixLen: rootRequired.count),
                    score: b.score(positionExponent: config.positionExponent),
                    totalLogprob: b.totalLogprob,
                    tokenCount: b.tokens.count
                )
            }
            .filter { !$0.ghost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.score > $1.score }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return BeamResult(best: scored.first, candidates: scored, elapsedMillis: elapsed,
                          promptTokenCount: promptTokens.count, reusedPrefixTokens: lcp,
                          prefillMillis: prefillMs, decodeMillis: decodeMs)
    }

    // MARK: - Étapes internes

    /// Tokens du prompt actuellement en KV (seq 0), pour le prefix-caching entre
    /// appels. Invalidé au load/unload/clearReserve (KV détruit ou wipé).
    private var cachedPromptTokens: [Int32] = []

    /// Préfille `suffix` en séquence 0 à partir de la position `fromPos` (batch
    /// explicite : logits activés sur la DERNIÈRE entrée seulement, mêmes
    /// sémantiques que `llama_batch_get_one`). `fromPos == 0` ⇒ prefill complet.
    private func prefill(suffix: [Int32], fromPos: Int32) -> Bool {
        guard let h = handles, !suffix.isEmpty else { return false }
        let n = suffix.count
        var batch = llama_batch_init(Int32(n), 0, h.nSeqMax)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(n)
        for i in 0..<n {
            batch.token[i] = suffix[i]
            batch.pos[i] = fromPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (i == n - 1) ? 1 : 0
        }
        return llama_decode(h.context, batch) == 0
    }

    /// Décode un batch multi-séquences : un token par branche vivante (le DERNIER
    /// token propre de la branche, ou — pour une branche sans token encore, la
    /// racine — rien à re-décoder car le prompt vient d'être préfillé en seq 0).
    ///
    /// Subtilité : à la 1ʳᵉ étape, la seule branche est la racine (seq 0), dont
    /// les logits next-token sont DÉJÀ disponibles après le préfill (dernière
    /// position du prompt). On ne re-décode donc rien et on lit `logits_ith(-1)`.
    /// Aux étapes suivantes, chaque branche a forké un token qu'il faut décoder
    /// dans SA séquence pour obtenir ses logits next-token.
    ///
    /// Retourne, pour chaque branche (même ordre que `branches`), un pointeur sur
    /// sa ligne de logits. nil si le décode échoue.
    private func decodeStep(branches: [Branch], promptLen: Int32, mem: llama_memory_t?) -> [UnsafeMutablePointer<Float>]? {
        guard let h = handles else { return nil }

        // Cas racine (étape 0) : aucun token propre nulle part → logits frais en -1.
        if branches.count == 1 && branches[0].tokens.isEmpty {
            guard let row = llama_get_logits_ith(h.context, -1) else { return nil }
            return [row]
        }

        // Construit un batch explicite : une entrée par branche = son DERNIER
        // token, à la position `promptLen + (tokens.count - 1)`, dans sa seqId,
        // avec `logits = 1` (on veut la distribution next-token de chaque
        // séquence). C'est le « decode multi-séquences ensemble » de la RE.
        let n = branches.count
        var batch = llama_batch_init(Int32(n), 0, h.nSeqMax)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(n)
        for (i, b) in branches.enumerated() {
            let tok = b.tokens.last!
            batch.token[i] = tok
            batch.pos[i] = promptLen + Int32(b.tokens.count - 1)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = b.seqId
            batch.logits[i] = 1
        }
        guard llama_decode(h.context, batch) == 0 else { return nil }

        // Récupère la ligne de logits de chaque entrée par son indice batch.
        var rows: [UnsafeMutablePointer<Float>] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            guard let row = llama_get_logits_ith(h.context, Int32(i)) else { return nil }
            rows.append(row)
        }
        return rows
    }

    /// Token candidat : son id et sa log-prob softmax sur la distribution.
    private struct NextToken { let tokenId: Int32; let logProb: Double }

    /// Calcule la softmax de `logits` et retourne les tokens dont la probabilité
    /// est ≥ `minProb` (les graines de branche), triés par log-prob décroissante,
    /// bornés à `maxSearchWidth` (jamais plus de fan-out que K). EOG inclus tel
    /// quel (un EOG très probable terminera la branche dans `extend`).
    ///
    /// **Plancher top-1** : si AUCUN token n'atteint `minProb` (distribution
    /// étalée — typique après une virgule : « et/il/qui/mais… » chacun < 5 %), on
    /// renvoie quand même le MEILLEUR token (décode greedy). Sinon la continuation
    /// LIBRE (au-delà du `requiredPrefix`) mourrait de faim et le ghost s'arrêterait
    /// au 1ᵉʳ mot (« entreprise, » → rien) au lieu de dérouler 2-3 mots. `minProb`
    /// ne pilote alors plus QUE le fan-out (combien de branches), pas l'arrêt.
    private func topNextTokens(logits: UnsafeMutablePointer<Float>, nVocab: Int, minProb: Double) -> [NextToken] {
        // max pour la stabilité numérique de la softmax (SIMD).
        var maxLogit: Float = -Float.greatestFiniteMagnitude
        vDSP_maxv(logits, 1, &maxLogit, vDSP_Length(nVocab))
        var sumExp: Double = 0
        for i in 0..<nVocab {
            let l = logits[i]
            if l > -Float.greatestFiniteMagnitude { sumExp += Double(expf(l - maxLogit)) }
        }
        guard sumExp > 0 else { return [] }
        let logZ = log(sumExp)   // log Σ exp(l - max)

        // Seuil en log-prob : log(minProb). Un token passe s'il a prob ≥ minProb.
        let logThresh = log(minProb)
        var out: [NextToken] = []
        var bestId: Int32 = -1
        var bestLp = -Double.greatestFiniteMagnitude
        for i in 0..<nVocab {
            let l = logits[i]
            if l <= -Float.greatestFiniteMagnitude { continue }
            let lp = Double(l - maxLogit) - logZ   // log P(token)
            if lp > bestLp { bestLp = lp; bestId = Int32(i) }   // plancher greedy
            if lp >= logThresh { out.append(NextToken(tokenId: Int32(i), logProb: lp)) }
        }
        // Plancher : rien au-dessus du seuil → on garde le meilleur token (greedy)
        // pour que la continuation libre ne s'arrête pas net.
        if out.isEmpty {
            return bestId >= 0 ? [NextToken(tokenId: bestId, logProb: bestLp)] : []
        }
        out.sort { $0.logProb > $1.logProb }
        if out.count > config.maxSearchWidth { out.removeLast(out.count - config.maxSearchWidth) }
        return out
    }

    /// Variante CONTRAINTE de `topNextTokens` pour le décodage mid-mot : ne
    /// retient que les tokens dont la surface est prefix-compatible avec le
    /// `required` restant, classés par log-prob brute (la contrainte remplace le
    /// `minBranchProbability`). `firstToken` tolère une métaspace de tête (le mot
    /// re-démarre à une frontière propre après healing). Borné à `maxSearchWidth`.
    ///
    /// Coût : un scan O(nVocab) des pièces avec test de compatibilité. Acceptable
    /// pour un SPIKE ; en prod on précalculerait un index préfixe. Les pièces
    /// sont mises en cache par token (cf. `compatPieceCache`).
    private func topCompatibleTokens(logits: UnsafeMutablePointer<Float>, nVocab: Int,
                                     required: String, firstToken: Bool) -> [NextToken] {
        var maxLogit: Float = -Float.greatestFiniteMagnitude
        vDSP_maxv(logits, 1, &maxLogit, vDSP_Length(nVocab))
        var sumExp: Double = 0
        for i in 0..<nVocab {
            let l = logits[i]
            if l > -Float.greatestFiniteMagnitude { sumExp += Double(expf(l - maxLogit)) }
        }
        guard sumExp > 0 else { return [] }
        let logZ = log(sumExp)

        let pieces = surfacePieceList()   // cache surface par token (1 build/load)
        // Index par 1er char (avec/sans espace de tête) : on ne scanne QUE les
        // tokens dont la surface peut commencer comme le required — bien plus
        // petit que les 256k du vocab. C'est l'optimisation clé du scan contraint.
        let firstScalar = required.unicodeScalars.first!
        let bucket = firstCharBucket(firstScalar)
        var out: [NextToken] = []
        for i in bucket {
            let l = logits[i]
            if l <= -Float.greatestFiniteMagnitude { continue }
            var surf = pieces[i]
            if firstToken, surf.first == " " { surf.removeFirst() }
            if surf.isEmpty { continue }
            // Compatible si le token complète/dépasse le required (surf.hasPrefix)
            // OU n'en consomme qu'une partie (required.hasPrefix(surf)).
            let compatible = surf.hasPrefix(required) || required.hasPrefix(surf)
            if !compatible { continue }
            let lp = Double(l - maxLogit) - logZ
            out.append(NextToken(tokenId: Int32(i), logProb: lp))
        }
        out.sort { $0.logProb > $1.logProb }
        if out.count > config.maxSearchWidth { out.removeLast(out.count - config.maxSearchWidth) }
        return out
    }

    /// Cache des surfaces (métaspace → espace) de TOUS les tokens du vocab,
    /// construit une fois par load. Lu par le décodage contraint mid-mot. Reset
    /// implicite : reconstruit si vide (load remet `surfacePieceCache = nil`).
    private var surfacePieceCache: [String]?
    private func surfacePieceList() -> [String] {
        if let c = surfacePieceCache { return c }
        guard let h = handles else { return [] }
        let n = Int(h.nVocab)
        var arr = [String](repeating: "", count: n)
        var id: Int32 = 0
        while id < Int32(n) { arr[Int(id)] = surface(id); id += 1 }
        surfacePieceCache = arr
        return arr
    }

    /// Index 1er-char → ids de tokens dont la surface (espace de tête retiré)
    /// commence par ce scalaire. Réduit le scan contraint mid-mot de 256k à la
    /// poignée de tokens du bon préfixe. Construit une fois par load (au 1er
    /// usage mid-mot), reset implicite via `surfacePieceCache = nil` au load.
    private var firstCharIndex: [Unicode.Scalar: [Int]]?
    private func firstCharBucket(_ scalar: Unicode.Scalar) -> [Int] {
        if firstCharIndex == nil {
            let pieces = surfacePieceList()
            var idx: [Unicode.Scalar: [Int]] = [:]
            for (i, raw) in pieces.enumerated() {
                var s = Substring(raw)
                if s.first == " " { s = s.dropFirst() }
                guard let first = s.unicodeScalars.first else { continue }
                idx[first, default: []].append(i)
            }
            firstCharIndex = idx
        }
        return firstCharIndex?[scalar] ?? []
    }

    /// Étend `branch` par `tokenId`. Applique la contrainte requiredPrefix :
    /// renvoie nil (branche tuée) si la surface du token est incompatible avec le
    /// reste du préfixe obligatoire. Gère la consommation PARTIELLE (un token qui
    /// ne couvre qu'une partie du préfixe restant).
    ///
    /// Forking KV : l'enfant a besoin de sa propre séquence si plusieurs enfants
    /// du même parent vivent. Pour rester simple et correct, CHAQUE enfant forke
    /// une nouvelle seqId via `llama_memory_seq_cp(parent → child)` — le coût est
    /// la copie du préfixe (cheap, déjà en KV), pas une re-décode. La seqId est
    /// tirée du pool ; si le pool est vide la branche est jetée (borne K dure).
    private func extend(branch: Branch, tokenId: Int32, logProb: Double) -> Branch? {
        guard let h = handles else { return nil }
        let surf = surface(tokenId)

        var child = branch
        // ── Contrainte requiredPrefix (mid-word) ─────────────────────────────
        if !branch.remainingRequiredPrefix.isEmpty {
            let req = branch.remainingRequiredPrefix
            // Le prompt a été « healé » à la frontière du mot, donc le PREMIER
            // token qui ré-émet le mot porte sa métaspace → un espace de tête.
            // Tant que rien du préfixe n'a encore été consommé, on tolère (et on
            // absorbe) cet unique espace de tête : il fait partie de la zone
            // déjà-tapée, jamais du ghost.
            var matchSurf = surf
            var leadingSpace = 0
            if branch.requiredPrefixConsumed == 0, matchSurf.first == " " {
                matchSurf.removeFirst(); leadingSpace = 1
            }
            if matchSurf.hasPrefix(req) {
                // Le token couvre (ou dépasse) tout le reste du préfixe → le mot
                // tapé est complété, le suffixe au-delà devient du ghost.
                child.remainingRequiredPrefix = ""
                child.requiredPrefixConsumed += req.count + leadingSpace
            } else if req.hasPrefix(matchSurf) && !matchSurf.isEmpty {
                // Le token consomme une PARTIE du préfixe restant (sous-fragment).
                child.remainingRequiredPrefix = String(req.dropFirst(matchSurf.count))
                child.requiredPrefixConsumed += matchSurf.count + leadingSpace
            } else {
                // Surface incompatible (diverge du mot tapé, ou espace en tête
                // = nouveau mot avant d'avoir fini celui-ci) → branche tuée.
                return nil
            }
        }

        // L'enfant DÉRIVE du KV de `branch.seqId` ; son propre seqId est assigné
        // PARESSEUSEMENT au pruning (le premier survivant d'un parent hérite la
        // seqId du parent, les autres forkent). On NE forke PAS ici — sinon on
        // épuiserait le pool de K seqIds dès la 1ʳᵉ étape (K parents × K enfants).
        child.parentSeqId = branch.seqId
        child.seqId = -1   // non assigné

        // EOG : on n'ajoute pas le token, on marque la branche finie.
        if llama_vocab_is_eog(h.vocab, tokenId) {
            child.finished = true
            return child
        }

        child.tokens.append(tokenId)
        child.surfaceText += surf
        child.totalLogprob += logProb
        return child
    }

    /// Réserve interne d'ids de séquence libres (1…K). La racine occupe 0.
    /// Reconstruite à chaque `generateBeam` via `resetSeqPool`.
    private var seqPool: [Int32] = []

    private func resetSeqPool() {
        guard let h = handles else { seqPool = []; return }
        seqPool = (1..<h.nSeqMax).map { $0 }
    }

    private func takeSeqId() -> Int32? {
        seqPool.popLast()
    }

    private func returnSeqId(_ id: Int32) {
        if id != 0 { seqPool.append(id) }
    }

    /// Assigne les seqIds KV des survivants et matérialise les forks nécessaires.
    /// Invariant : à l'entrée, chaque survivant porte `parentSeqId` (la seqId dont
    /// son KV dérive) et `seqId == -1`. Pour chaque parent, le PREMIER survivant
    /// hérite la seqId du parent (extension en place — son nouveau token sera
    /// décodé dans cette seq au prochain `decodeStep`). Les survivants suivants
    /// du même parent reçoivent une seqId FRAÎCHE et `seq_cp(parent → fresh)`
    /// copie le préfixe partagé. Les seqIds parentes que PERSONNE n'hérite sont
    /// effacées et rendues au pool (recyclage KV des branches abandonnées).
    private func assignSeqIds(survivors: inout [Branch], parentsAlive: [Branch], mem: llama_memory_t?) {
        // 1) Détermine d'abord quelles seqIds parentes sont HÉRITÉES (le 1er
        //    survivant de chaque parent). Les autres parents sont abandonnés.
        var claimed = Set<Int32>()
        for b in survivors where !claimed.contains(b.parentSeqId) { claimed.insert(b.parentSeqId) }

        // 2) RECYCLE d'abord les parents non hérités → ré-alimente le pool AVANT
        //    de forker (sinon le pool, plein des K seqIds de l'étape précédente,
        //    serait vide au moment des copies).
        let parentSeqIds = Set(parentsAlive.map { $0.seqId })
        for sid in parentSeqIds where sid != 0 && !claimed.contains(sid) {
            if let mem { llama_memory_seq_rm(mem, sid, -1, -1) }
            returnSeqId(sid)
        }

        // 3) Assigne : 1er survivant d'un parent → en place ; suivants → fork.
        var inheritedThisStep = Set<Int32>()
        for i in survivors.indices {
            let parent = survivors[i].parentSeqId
            if !inheritedThisStep.contains(parent) {
                survivors[i].seqId = parent
                inheritedThisStep.insert(parent)
            } else if let fresh = takeSeqId() {
                if let mem { llama_memory_seq_cp(mem, parent, fresh, 0, -1) }
                survivors[i].seqId = fresh
            } else {
                survivors[i].seqId = -2   // pool épuisé → drop (borne K dure)
            }
        }
        survivors.removeAll { $0.seqId == -2 }
    }

    /// Élagage top-K : trie par score décroissant, fixe `threshold = scores[K-1]`,
    /// garde les candidats de score ≥ threshold, puis applique la coupe relative
    /// (`relativeCutoff`) par rapport au meilleur. Les rejetés voient leur KV
    /// recyclé.
    private func pruneTopK(_ branches: [Branch]) -> [Branch] {
        guard !branches.isEmpty else { return [] }
        let sorted = branches.sorted {
            $0.score(positionExponent: config.positionExponent)
          > $1.score(positionExponent: config.positionExponent)
        }
        let k = config.maxResultWidth
        let best = sorted[0].score(positionExponent: config.positionExponent)
        let relFloor = best + log(config.relativeCutoff)   // log : best + log(1e-10)

        // Les candidats ici ont un seqId NON encore assigné (-1) : le recyclage KV
        // des rejetés est géré centralement par `assignSeqIds` (une seqId parente
        // qu'aucun survivant n'hérite est effacée). On ne fait donc QUE
        // sélectionner ici — aucun effet KV.
        var kept: [Branch] = []
        let threshold = k <= sorted.count
            ? sorted[k - 1].score(positionExponent: config.positionExponent)
            : -Double.greatestFiniteMagnitude
        for (idx, b) in sorted.enumerated() {
            let s = b.score(positionExponent: config.positionExponent)
            let withinK = idx < k && s >= threshold
            let withinRel = s >= relFloor
            if withinK && withinRel { kept.append(b) }
        }
        return kept
    }

    /// Arrêt par candidat : frontière de phrase / clause, ou budget de mots
    /// atteint. Esprit des caps long-ghost (~4 mots). On arrête PROPREMENT à une
    /// ponctuation de fin de phrase pour ne pas franchir une frontière de phrase.
    private func shouldStop(branch: Branch) -> Bool {
        if branch.finished { return true }
        let text = branch.surfaceText
        // Budget mots (le ghost utile au-delà du requiredPrefix).
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if words >= config.maxWords { return true }
        // Frontière de phrase : un . ! ? ou newline en fin de surface clôt.
        if let last = text.last, ".!?\n".contains(last) { return true }
        return false
    }

    /// Construit le texte du ghost d'une branche : sa surface produite, moins la
    /// partie qui appartenait au requiredPrefix déjà tapé (mid-word). On nettoie
    /// un éventuel espace de tête (après-espace, la 1ʳᵉ surface porte sa
    /// métaspace → espace de tête à retirer pour un ghost « collé » au caret).
    private func ghostText(of branch: Branch, requiredPrefixLen: Int) -> String {
        var s = branch.surfaceText
        // Retire les caractères qui re-tapent le fragment déjà tapé (mid-word).
        let drop = min(branch.requiredPrefixConsumed, s.count)
        if drop > 0 { s = String(s.dropFirst(drop)) }
        // En après-espace (pas de requiredPrefix), la 1ʳᵉ surface a un espace de
        // tête (métaspace) : on le conserve PAS — le ghost se colle au caret et
        // l'appelant gère l'espace. On retire un unique espace de tête.
        if requiredPrefixLen == 0, s.first == " " { s.removeFirst() }
        return s
    }

    // MARK: - Réserve : structure & capture

    /// Une branche conservée VIVANTE pour la réutilisation à la frappe suivante.
    /// Son KV (préfixe partagé + `tokens`) vit sous `seqId` ; `surfaceSuffix` est
    /// le texte ghost déjà décodé (au-delà du requiredPrefix initial) ; `consumed`
    /// compte les chars de ce suffixe que l'utilisateur a tapés depuis. Le ghost
    /// courant d'une réserve = `surfaceSuffix` à partir de l'offset `consumed`.
    private struct ReservedBranch {
        let seqId: Int32
        var tokens: [Int32]          // tokens propres (hors prompt) déjà décodés
        var totalLogprob: Double
        var surfaceSuffix: String    // texte ghost déjà calculé (post requiredPrefix)
        var consumed: Int            // chars de surfaceSuffix déjà tapés par l'utilisateur

        /// Le ghost restant à afficher (suffixe non encore tapé).
        var remainingGhost: String {
            consumed >= surfaceSuffix.count ? "" : String(surfaceSuffix.dropFirst(consumed))
        }
        /// Profondeur restante en chars pré-calculés (santé de la réserve).
        var depthLeft: Int { max(0, surfaceSuffix.count - consumed) }
    }

    /// Profondeur (en chars) sous laquelle on déclenche un REFILL incrémental :
    /// si après une frappe une réserve survivante a moins que ça d'avance, on
    /// re-décode quelques tokens — seulement sur les survivants — pour reconstituer
    /// le ghost. Statique, style maison.
    /// 10 chars ≈ ~2 mots d'avance : on prolonge AVANT que le ghost ne se vide,
    /// pour garder un lookahead vivant (living ghost) au lieu de re-beamer à sec.
    private static let refillThresholdChars = 10
    /// Nombre de tokens re-décodés par survivant lors d'un refill. Borné : le
    /// refill doit rester BIEN moins cher qu'un beam froid (pas de re-fan-out).
    /// 12 ≈ ~3 mots de suite régénérés par top-up.
    private static let refillTokens = 12

    /// Recadre le suffixe ghost d'une branche (comme `ghostText`) pour le matching
    /// de frappe : retire la partie re-tapée du requiredPrefix, élide l'espace de
    /// tête after-space. Renvoie nil si le suffixe est vide/blanc.
    private func reserveSuffix(of b: Branch, rootRequired: String) -> String? {
        guard b.remainingRequiredPrefix.isEmpty, !b.tokens.isEmpty else { return nil }
        var s = b.surfaceText
        let drop = min(b.requiredPrefixConsumed, s.count)
        if drop > 0 { s = String(s.dropFirst(drop)) }
        // After-space : la 1ʳᵉ surface porte sa métaspace → espace de tête. On
        // l'élide comme `ghostText` ; sinon le 1ᵉʳ char comparé au matching serait
        // un espace et la frappe d'une lettre raterait toujours (faux MISS).
        if rootRequired.isEmpty, s.first == " " { s.removeFirst() }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return s
    }

    /// Construit la réserve depuis les branches `live` (KV vivant, refillables) ET
    /// `finished` (arrêtées, suffixe figé, sans KV). Dé-doublonne par suffixe en
    /// PRÉFÉRANT la version KV-vivante (`seqId ≥ 0`) quand le même texte existe des
    /// deux côtés. Mémorise le prompt d'origine pour un MISS.
    private func buildReserve(live: [Branch], finished: [Branch],
                              rootRequired: String, prompt: String) {
        // 1) Branches vivantes : seqId réel, refillables.
        var bySuffix: [String: ReservedBranch] = [:]
        var order: [String] = []
        for b in live {
            guard let s = reserveSuffix(of: b, rootRequired: rootRequired) else { continue }
            if bySuffix[s] == nil { order.append(s) }
            bySuffix[s] = ReservedBranch(seqId: b.seqId, tokens: b.tokens,
                                         totalLogprob: b.totalLogprob, surfaceSuffix: s, consumed: 0)
        }
        // 2) Branches arrêtées : gelées (seqId = -1), affichables sans KV. On
        //    n'écrase PAS une entrée vivante de même suffixe (KV > gelé).
        for b in finished {
            guard let s = reserveSuffix(of: b, rootRequired: rootRequired) else { continue }
            if bySuffix[s] != nil { continue }
            order.append(s)
            bySuffix[s] = ReservedBranch(seqId: -1, tokens: b.tokens,
                                         totalLogprob: b.totalLogprob, surfaceSuffix: s, consumed: 0)
        }
        // Trie par score NORMALISÉ par longueur (cohérent avec le ranking final du
        // beam, `positionExponent`), pas par log-prob brute — sinon la réserve
        // re-préfère systématiquement le suffixe le plus COURT et le reuse (HIT)
        // annulerait la length-norm appliquée au seed. Borne à K.
        reserve = order.compactMap { bySuffix[$0] }
            .sorted { reserveScore($0) > reserveScore($1) }
        if reserve.count > config.maxResultWidth { reserve.removeLast(reserve.count - config.maxResultWidth) }
        reservePrompt = prompt
        reserveTypedSoFar = ""
    }

    /// La réserve a-t-elle des branches exploitables par `advance` ?
    public var hasReserve: Bool { !reserve.isEmpty }

    /// Abandonne la réserve SANS toucher au KV : les séquences de branches sont
    /// recyclées par le prochain `generateBeam` (qui les efface), et le
    /// prefix-cache du prompt (seq 0) reste exploitable. À préférer à
    /// `clearReserve` entre deux sessions de frappe — `clearReserve` wipe TOUT
    /// le KV et perd le bénéfice du prefix-caching.
    public func dropReserve() {
        reserve = []
        reservePrompt = ""
        reserveTypedSoFar = ""
    }

    /// Vide la réserve et libère son KV (toutes séquences). À appeler quand on
    /// abandonne une session de frappe.
    public func clearReserve() {
        guard let h = handles else { reserve = []; return }
        if let mem = llama_get_memory(h.context) { llama_memory_seq_rm(mem, -1, -1, -1) }
        reserve = []
        reservePrompt = ""
        reserveTypedSoFar = ""
        cachedPromptTokens = []   // KV wipé → le prefix-cache ne pointe plus sur rien
    }

    // MARK: - Réserve : avance à la frappe (HIT / REFILL / MISS)

    /// Avance la réserve d'UN caractère tapé. C'est le chemin chaud Cotypist :
    ///  • HIT   — ≥1 réserve avait `typedChar` en tête de son ghost restant : on
    ///            avance leur pointeur `consumed`, on jette les divergentes (leur KV
    ///            est effacé via `seq_rm`). AUCUN `llama_decode`. ~0 ms.
    ///  • REFILL— survivants OK mais ghost devenu trop court : on re-décode quelques
    ///            tokens sur les SEULS survivants (greedy, profondeur seule).
    ///  • MISS  — aucune réserve compatible : re-beam complet (coût froid).
    ///
    /// `requiredPrefixForMiss` : le fragment mid-mot au moment d'un MISS (l'éval le
    /// passe ; vide en after-space).
    /// Exécute `body` avec la largeur K de la config temporairement clampée à
    /// `maxWidth` (≥1, ≤ K de chargement), puis restaurée. nil ⇒ K inchangé. Sûr
    /// (actor sérialisé) ; le pool de seqIds dépend de `n_seq_max` au CHARGEMENT,
    /// pas de cette largeur, donc clamper ne casse jamais le fork KV.
    private func withConfigWidth<T>(_ maxWidth: Int?, _ body: () -> T) -> T {
        guard let mw = maxWidth else { return body() }
        let saved = config
        let w = max(1, min(mw, saved.maxSearchWidth))
        config.maxSearchWidth = w
        config.maxResultWidth = w
        defer { config = saved }
        return body()
    }

    public func advance(typedChar: Character, requiredPrefixForMiss: String = "",
                        missWidth: Int? = nil) -> AdvanceResult {
        let start = Date()
        guard handles != nil else {
            return AdvanceResult(ghost: "", kind: .miss, elapsedMillis: 0, survivors: 0)
        }

        // ── Match : quelles réserves ont `typedChar` en tête de leur ghost ? ──
        // On compare au 1ᵉʳ char NON consommé. Les espaces sont gérés tels quels
        // (taper l'espace consomme l'espace de tête d'un futur « mot suivant »).
        var survivors: [ReservedBranch] = []
        var dropped: [ReservedBranch] = []
        for var r in reserve {
            if r.consumed < r.surfaceSuffix.count {
                let idx = r.surfaceSuffix.index(r.surfaceSuffix.startIndex, offsetBy: r.consumed)
                if r.surfaceSuffix[idx] == typedChar {
                    r.consumed += 1            // avance dans le KV déjà calculé
                    survivors.append(r)
                    continue
                }
            }
            dropped.append(r)                  // diverge (ou suffixe épuisé) → à recycler
        }

        // Recycle le KV des divergentes : efface leur séquence. On garde > 0 :
        //  • seqId 0  = la séquence du prompt partagé (jamais à effacer ici),
        //  • seqId -1 = un candidat GELÉ sans KV (rien à effacer),
        //  • seqId -1 passé à seq_rm = wildcard « toutes séquences » → DANGER.
        let mem = handles.flatMap { llama_get_memory($0.context) }
        for d in dropped where d.seqId > 0 {
            if let mem { llama_memory_seq_rm(mem, d.seqId, -1, -1) }
        }

        reserveTypedSoFar.append(typedChar)

        // ── MISS : plus aucune réserve compatible → re-beam froid ────────────
        if survivors.isEmpty {
            // Le préfixe a avancé d'un char : on re-beame sur prompt + texte tapé.
            let newPrompt = reservePrompt + reserveTypedSoFar
            resetSeqPool()
            // Re-beam à la largeur du contexte courant (mid-mot K=3, frontière K=1).
            let r = withConfigWidth(missWidth) {
                generateBeam(prompt: newPrompt, requiredPrefix: requiredPrefixForMiss,
                             captureReserve: true)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return AdvanceResult(ghost: r.best?.ghost ?? "", kind: .miss,
                                 elapsedMillis: ms, survivors: reserve.count)
        }

        reserve = survivors

        // ── REFILL : prolonger le ghost MID-PHRASE dès qu'il s'épuise ─────────
        // On regarde le MEILLEUR survivant (celui affiché) : s'il reste peu de
        // profondeur ET qu'on n'est PAS en fin de phrase, on PROLONGE (living
        // ghost « continue dès qu'un mot est tapé »). Deux cas :
        //  • une branche VIVANTE (seqId ≥ 0) existe → top-up greedy en profondeur
        //    (refillSurvivors, ~quelques décodes, pas de fan-out — cheap) ;
        //  • toutes GELÉES (arrêtées sur budget, KV mort) → re-beam frais pour
        //    régénérer une suite (coût froid, mais c'est la frappe de dépletion).
        // En FIN DE PHRASE (le suffixe se termine par . ! ?), on NE prolonge pas :
        // le ghost se vide proprement, on laisse l'utilisateur clore la phrase.
        let best = reserve.max(by: { reserveScore($0) < reserveScore($1) })
        let bestShallow = (best?.depthLeft ?? 0) < BeamGhostEngine.refillThresholdChars
        let atSentenceEnd: Bool = {
            guard let s = best?.surfaceSuffix.trimmingCharacters(in: .whitespacesAndNewlines),
                  let last = s.last else { return false }
            return ".!?".contains(last)
        }()
        if bestShallow && !atSentenceEnd {
            if reserve.contains(where: { $0.seqId >= 0 }) {
                refillSurvivors()
                let ghost = bestReserveGhost()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return AdvanceResult(ghost: ghost, kind: .refill, elapsedMillis: ms, survivors: reserve.count)
            } else {
                // Toutes gelées → re-beam pour régénérer la continuation.
                let newPrompt = reservePrompt + reserveTypedSoFar
                resetSeqPool()
                let r = withConfigWidth(missWidth) {
                    generateBeam(prompt: newPrompt, requiredPrefix: requiredPrefixForMiss,
                                 captureReserve: true)
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return AdvanceResult(ghost: r.best?.ghost ?? "", kind: .refill,
                                     elapsedMillis: ms, survivors: reserve.count)
            }
        }

        // ── HIT : zéro decode, le ghost est le reste du suffixe pré-calculé ──
        let ghost = bestReserveGhost()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return AdvanceResult(ghost: ghost, kind: .hit, elapsedMillis: ms, survivors: reserve.count)
    }

    /// Le ghost à afficher : le suffixe restant du MEILLEUR survivant, classé par
    /// score NORMALISÉ par longueur (cohérent avec le seed ; le drop/refill peut
    /// réordonner). Sans normalisation, on re-préférerait le suffixe le plus court.
    private func bestReserveGhost() -> String {
        reserve.max(by: { reserveScore($0) < reserveScore($1) })?.remainingGhost ?? ""
    }

    /// Score d'une branche de réserve, normalisé par longueur via
    /// `config.positionExponent` (miroir de `Branch.score`) — `totalLogprob /
    /// pow(nbTokens, exponent)`. À exponent 0 ⇒ somme pure (court-biaisé).
    private func reserveScore(_ r: ReservedBranch) -> Double {
        r.totalLogprob / pow(Double(max(1, r.tokens.count)), config.positionExponent)
    }

    /// Re-décode GREEDY quelques tokens sur chaque survivant — uniquement en
    /// profondeur (1 token next par séquence, pas de fan-out). Étend `tokens`,
    /// `surfaceSuffix`, `totalLogprob`. C'est le « top-up incrémental » : on
    /// réutilise le KV vivant du survivant et on n'y ajoute que la profondeur
    /// manquante. Coût ≈ refillTokens passes mono-token sur K séquences.
    private func refillSurvivors() {
        guard let h = handles, !reserve.isEmpty else { return }
        // Position du prochain token d'un survivant = (longueur du prompt d'origine)
        // + |tokens propres|. Le KV de ces tokens vit DÉJÀ à ces positions ; on
        // re-tokenise le prompt d'origine (`reservePrompt`, invariant entre frappes
        // HIT) pour retrouver `basePos`. Le requiredPrefix healing du prompt n'altère
        // pas cette base car la réserve provient d'un beam sur ce même prompt.
        let basePos = Int32(tokenize(reservePrompt, addSpecial: true).count)

        for _ in 0..<BeamGhostEngine.refillTokens {
            // Même cancel-on-keystroke que la boucle de décodage du beam : un
            // top-up périmé ne doit pas retenir l'actor (la réserve reste
            // cohérente — les tokens déjà re-décodés sont simplement plus
            // profonds que nécessaire).
            if Task.isCancelled { break }
            // Indices des survivants REFILLABLES (KV vivant). Les gelés (seqId == -1)
            // n'ont pas de séquence à décoder → exclus du batch.
            let idxs = reserve.indices.filter { reserve[$0].seqId >= 0 && !reserve[$0].tokens.isEmpty }
            if idxs.isEmpty { break }
            var batch = llama_batch_init(Int32(idxs.count), 0, h.nSeqMax)
            defer { llama_batch_free(batch) }
            batch.n_tokens = Int32(idxs.count)
            for (bi, ri) in idxs.enumerated() {
                let r = reserve[ri]
                batch.token[bi] = r.tokens.last!
                batch.pos[bi] = basePos + Int32(r.tokens.count - 1)
                batch.n_seq_id[bi] = 1
                batch.seq_id[bi]![0] = r.seqId
                batch.logits[bi] = 1
            }
            guard llama_decode(h.context, batch) == 0 else { return }
            let nVocab = Int(h.nVocab)
            var stop = true
            for (bi, ri) in idxs.enumerated() {
                guard let row = llama_get_logits_ith(h.context, Int32(bi)) else { continue }
                // Greedy argmax (le refill ne ré-ouvre pas de branches).
                var best: Int32 = 0; var bestVal: Float = -.greatestFiniteMagnitude
                for v in 0..<nVocab where row[v] > bestVal { bestVal = row[v]; best = Int32(v) }
                if llama_vocab_is_eog(h.vocab, best) { continue }
                let surf = surface(best)
                reserve[ri].tokens.append(best)
                reserve[ri].surfaceSuffix += surf
                stop = false
            }
            if stop { break }
        }
    }

    // MARK: - Entrée publique avec reset du pool

    /// Variante publique qui RÉINITIALISE le pool de séquences avant de lancer la
    /// recherche (indispensable entre deux appels). C'est le point d'entrée à
    /// utiliser depuis l'éval / un call-site gaté.
    public func ghost(prompt: String, requiredPrefix: String = "") -> BeamResult {
        resetSeqPool()
        return generateBeam(prompt: prompt, requiredPrefix: requiredPrefix)
    }

    /// One-shot à largeur EXPLICITE pour CET appel (override du K de la config).
    /// C'est le point d'entrée du cœur de prod : le mid-mot tourne au K plein
    /// (3 — la contrainte trie les complétions), l'après-espace à K=1 (≡ greedy,
    /// le beam n'aide pas là-bas et K>1 y PERD en cohérence, cf. handoff §e). Le
    /// contexte est chargé à `n_seq_max = configK + 1`, donc tout `maxWidth` ≤ K
    /// de chargement tient sans re-créer le contexte. La mutation de `config` est
    /// sûre (actor sérialisé) et restaurée en `defer`.
    public func ghost(prompt: String, requiredPrefix: String, maxWidth: Int) -> BeamResult {
        withConfigWidth(maxWidth) {
            resetSeqPool()
            return generateBeam(prompt: prompt, requiredPrefix: requiredPrefix)
        }
    }

    /// Variante qui lance le beam ET capture la réserve, pour DÉMARRER une session
    /// de frappe réutilisable. Le premier appel = le « cold first-paint » ; ensuite
    /// l'appelant utilise `advance(typedChar:)` à chaque frappe. `maxWidth` clampe
    /// le K pour CE seed (mid-mot K=3, frontière K=1) ; nil ⇒ K de la config.
    public func ghostWithReserve(prompt: String, requiredPrefix: String = "",
                                 maxWidth: Int? = nil) -> BeamResult {
        withConfigWidth(maxWidth) {
            resetSeqPool()
            return generateBeam(prompt: prompt, requiredPrefix: requiredPrefix, captureReserve: true)
        }
    }
}
