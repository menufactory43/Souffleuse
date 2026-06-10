import Foundation
import Observation
import SouffleuseCore
import SouffleusePersonalization
import SouffleuseInput

/// Catalogue of selectable models. IDs match `mlx-community/...` repos
/// resolvable by LLMModelFactory. The actual download is triggered by
/// PredictorViewModel.swapModel — this struct is metadata only.
enum CompletionLength: String, CaseIterable, Sendable {
    case short, medium, long

    var label: String {
        switch self {
        case .short: return "Court (~1 mot)"
        case .medium: return "Moyen (~2-4 mots)"
        case .long: return "Long (phrase complète)"
        }
    }

    /// Hard token backstop fed to GenerateParameters. This is NO LONGER the
    /// primary brake — generation stops on the COMPLETE-word budget (`maxWords`,
    /// via `ChunkFilter.reachedWordCap`) or a sentence terminator, whichever
    /// comes first, so in the common case far fewer tokens are decoded than this
    /// ceiling. The ceiling only bites in pathological runs (the model never
    /// completing a word) to bound latency.
    ///
    /// Why generous: measured on the default Gemma 3 1B tokenizer, French words
    /// cost ~1.2 tok (courant) but élisions/long words cost 3-4 ("l'arbre" = 3,
    /// "définitivement" = 4). The old caps (short 3 / medium 4) were roughly the
    /// cost of a SINGLE elided word, so the budget routinely ran out mid-word
    /// and the ghost froze on "l'". The ceiling is sized at ≈ `maxWords × 4 + 2`
    /// so "finish the current word" almost never hits it. TTFT is unaffected
    /// (first token unchanged); only the stream tail can grow, and only when a
    /// word is genuinely unfinished.
    var maxTokens: Int {
        switch self {
        case .short: return 10
        case .medium: return 14
        case .long: return 40
        }
    }

    /// Max whole words shown in the ghost text, applied in `onChunk` after the
    /// model emits raw text. Tokens don't map 1:1 to words in French (sentence
    /// piece tokenisers fragment a lot), so an additional word cap keeps the
    /// "Court" preset feeling actually short.
    /// `medium` defaults to 3 words to match the Cotypist-like feel — short,
    /// punchy ghosts with the user Tab-walking through them.
    var maxWords: Int {
        switch self {
        case .short: return 2
        case .medium: return 3
        case .long: return 20
        }
    }
}

struct ModelOption: Identifiable, Sendable, Hashable {
    let id: String
    let displayName: String
    let approxDiskGB: Double
    let approxRamGB: Double
    let languages: String

    static let catalogue: [ModelOption] = [
        ModelOption(
            id: "mlx-community/gemma-3-1b-pt-4bit",
            displayName: "Gemma 3 1B base (4-bit)",
            approxDiskGB: 0.8,
            approxRamGB: 1.5,
            languages: "FR · EN · multilingue (défaut — continuation pure)"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-1b-pt-6bit",
            displayName: "Gemma 3 1B base (6-bit)",
            approxDiskGB: 1.0,
            approxRamGB: 1.7,
            languages: "FR · EN · multilingue (sweet spot qualité/taille — équivalent MLX du Q5_K_M imatrix de Cotypist)"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-1b-pt-8bit",
            displayName: "Gemma 3 1B base (8-bit)",
            approxDiskGB: 1.3,
            approxRamGB: 2.0,
            languages: "FR · EN · multilingue (≈ qualité bf16, TTFT similaire au 4-bit)"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-1b-it-4bit",
            displayName: "Gemma 3 1B Instruct (4-bit)",
            approxDiskGB: 0.8,
            approxRamGB: 1.5,
            languages: "Suit le system prompt mais tendance à reformuler (test only)"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-1b-it-qat-4bit",
            displayName: "Gemma 3 1B Instruct QAT (4-bit)",
            approxDiskGB: 0.8,
            approxRamGB: 1.5,
            languages: "Variante QAT de l'Instruct (test only)"
        ),
        ModelOption(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 1.5B Instruct (4-bit)",
            approxDiskGB: 1.0,
            approxRamGB: 2.0,
            languages: "FR · EN · multilingue (plus précis, plus gros)"
        ),
        ModelOption(
            id: "mlx-community/Qwen2.5-0.5B-4bit",
            displayName: "Qwen 2.5 0.5B base (4-bit)",
            approxDiskGB: 0.4,
            approxRamGB: 0.9,
            languages: "EN · multilingue (le plus léger)"
        ),
    ]
}

/// Single source of truth for user preferences. AppDelegate observes mutations
/// via @Observable and applies side effects (pause pipeline, reload model, etc.).
@MainActor
@Observable
final class PreferencesStore {
    // Defaults keys are typed so we can't typo at the call site.
    private enum K {
        static let enabled = "enabled"
        static let enrichmentEnabled = "enrichmentEnabled"
        static let captureEnabled = "captureEnabled"
        static let modelID = "modelID"
        static let ggufModelID = "ggufModelID"
        static let primaryLanguage = "primaryLanguage"
        static let ocrLangFR = "ocrLangFR"
        static let ocrLangEN = "ocrLangEN"
        static let ocrLangES = "ocrLangES"
        static let typoEnabled = "typoEnabled"
        static let emojiEnabled = "emojiEnabled"
        static let completionLength = "completionLength"
        static let hideOnTypo = "hideOnTypo"
        static let personalizationEnabled = "personalizationEnabled"
        static let personalizationStrength = "personalizationStrength"
        static let personalizationOnboardingShown = "personalizationOnboardingShown"
        static let storeWithoutAccepted = "storeWithoutAccepted"
        static let partialAcceptEnabled = "partialAcceptEnabled"
        static let acceptAllKey = "acceptAllKey"
        static let commitKey = "commitKey"
        static let translateHotKey = "translateHotKey"
        static let targetCycleKey = "targetCycleKey"
        static let translationModel = "translationModel"
        static let trailingSpaceOnPartial = "trailingSpaceOnPartial"
        static let prefixCorrectionEnabled = "prefixCorrectionEnabled"
        static let midLineGhostEnabled = "midLineGhostEnabled"
    }

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: K.enabled) }
    }
    var enrichmentEnabled: Bool {
        didSet { UserDefaults.standard.set(enrichmentEnabled, forKey: K.enrichmentEnabled) }
    }
    var captureEnabled: Bool {
        didSet { UserDefaults.standard.set(captureEnabled, forKey: K.captureEnabled) }
    }
    var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: K.modelID) }
    }
    /// Selected **GGUF (llama.cpp)** model id — the model that actually drives
    /// the ghost. Persists across restarts. Default = the fast 1B Q5 entry.
    /// (The MLX `modelID` above is legacy and no longer user-driven.)
    var ggufModelID: String {
        didSet { UserDefaults.standard.set(ggufModelID, forKey: K.ggufModelID) }
    }
    /// Langue d'écriture principale — demandée à l'onboarding, modifiable dans
    /// l'onglet Souffle. Sert UNIQUEMENT à conseiller la bonne voix (la petite
    /// Gemma en français, une voix multilingue sinon) ; ne change rien d'autre.
    var primaryLanguage: PrimaryLanguage {
        didSet { UserDefaults.standard.set(primaryLanguage.rawValue, forKey: K.primaryLanguage) }
    }
    var ocrLangFR: Bool { didSet { UserDefaults.standard.set(ocrLangFR, forKey: K.ocrLangFR) } }
    var ocrLangEN: Bool { didSet { UserDefaults.standard.set(ocrLangEN, forKey: K.ocrLangEN) } }
    var ocrLangES: Bool { didSet { UserDefaults.standard.set(ocrLangES, forKey: K.ocrLangES) } }
    var typoEnabled: Bool { didSet { UserDefaults.standard.set(typoEnabled, forKey: K.typoEnabled) } }
    var emojiEnabled: Bool { didSet { UserDefaults.standard.set(emojiEnabled, forKey: K.emojiEnabled) } }
    var completionLength: CompletionLength {
        didSet { UserDefaults.standard.set(completionLength.rawValue, forKey: K.completionLength) }
    }
    var hideOnTypo: Bool { didSet { UserDefaults.standard.set(hideOnTypo, forKey: K.hideOnTypo) } }
    var personalizationEnabled: Bool {
        didSet { UserDefaults.standard.set(personalizationEnabled, forKey: K.personalizationEnabled) }
    }
    /// 0.0 (off) → 2.0 (max). Multiplied with per-token n-gram log-prob inside
    /// the logit bias.
    var personalizationStrength: Double {
        didSet { UserDefaults.standard.set(personalizationStrength, forKey: K.personalizationStrength) }
    }
    /// Force de personnalisation EFFECTIVE propagée au predictor : la force réglée
    /// quand le toggle est ON, sinon `0`. Source unique de l'invariant « toggle
    /// OFF ⇒ force 0 » — avant, ce ternaire était dupliqué dans deux endroits de
    /// `SouffleuseAppDelegate` (init + sync de prefs), au risque de diverger. Le
    /// predictor fast-path et saute le biais n-gram dès que c'est `0`.
    var effectivePersonalizationStrength: Float {
        personalizationEnabled ? Float(personalizationStrength) : 0
    }
    var personalizationOnboardingShown: Bool {
        didSet { UserDefaults.standard.set(personalizationOnboardingShown, forKey: K.personalizationOnboardingShown) }
    }
    /// When true, the corpus also records the contents of a text field on focus
    /// change — even when the user accepted NO completion (Cotypist's "Store
    /// Inputs Without Accepted Completions"). Builds a richer style/vocabulary
    /// dataset from everything written, not just acceptances. Gated by
    /// `personalizationEnabled` + the same blocklist / secret / fragment checks.
    /// Default false (the more private, accepted-only mode).
    var storeWithoutAccepted: Bool {
        didSet { UserDefaults.standard.set(storeWithoutAccepted, forKey: K.storeWithoutAccepted) }
    }
    /// When true, Tab on an LLM suggestion accepts only the next word (with
    /// optional trailing space). The remainder stays in the ghost; Tab again
    /// accepts the next word. Cotypist-style. Default on.
    var partialAcceptEnabled: Bool {
        didSet { UserDefaults.standard.set(partialAcceptEnabled, forKey: K.partialAcceptEnabled) }
    }
    /// Which key accepts the WHOLE ghost in one press (vs Tab = word-by-word).
    /// Default → (right arrow); changeable in Preferences. `.disabled` turns it off.
    var acceptAllKey: AcceptAllKey {
        didSet { UserDefaults.standard.set(acceptAllKey.rawValue, forKey: K.acceptAllKey) }
    }
    /// Défaut ⌘↩ ; changeable dans Préférences. Valide le HUD de traduction
    /// (remplace la ligne du champ par le texte en langue cible). `.disabled` off.
    var commitKey: CommitKey {
        didSet { UserDefaults.standard.set(commitKey.rawValue, forKey: K.commitKey) }
    }
    /// Défaut ⌘⇧→ ; fait défiler la langue cible (EN→ES→DE→IT→AUTO) pour la
    /// conversation courante, pendant qu'un ghost s'affiche. `.disabled` off.
    var targetCycleKey: TargetCycleKey {
        didSet { UserDefaults.standard.set(targetCycleKey.rawValue, forKey: K.targetCycleKey) }
    }
    /// Défaut ⌥⌘T ; raccourci GLOBAL (hot key système) qui traduit le champ
    /// focus à TOUT moment — sans ghost actif ni HUD visible. `.disabled` off.
    var translateHotKey: TranslateHotKeyOption {
        didSet { UserDefaults.standard.set(translateHotKey.rawValue, forKey: K.translateHotKey) }
    }
    /// Modèle utilisé pour la TRADUCTION (ghost FR inchangé). Le changer recharge
    /// paresseusement l'autre GGUF ; déchargé à l'idle (Phase 7).
    var translationModel: InstructModel {
        didSet { UserDefaults.standard.set(translationModel.rawValue, forKey: K.translationModel) }
    }
    /// When true, partial accept includes the single space following the
    /// accepted word/punctuation so the caret lands ready for the next word.
    /// Default on.
    var trailingSpaceOnPartial: Bool {
        didSet { UserDefaults.standard.set(trailingSpaceOnPartial, forKey: K.trailingSpaceOnPartial) }
    }
    /// When true, obvious typos in COMPLETED words are silently corrected in the
    /// text fed to the model (never in what the user sees), so the ghost
    /// completes from a clean prefix. The in-progress last word is never
    /// touched. Default on; off → identity (model receives the raw prefix).
    var prefixCorrectionEnabled: Bool {
        didSet { UserDefaults.standard.set(prefixCorrectionEnabled, forKey: K.prefixCorrectionEnabled) }
    }
    /// When true, a ghost may appear even when the caret sits INSIDE a line
    /// (non-whitespace text follows on the same line). Instead of the inline
    /// ghost — which would overlap the following glyphs — the suggestion is
    /// shown as a rounded pill floated below the caret line (Cotypist's "Mid-line
    /// completion"). Default OFF: it's a distinct presentation and a behaviour
    /// change from the long-standing "suppress mid-line" rule, so it stays opt-in.
    var midLineGhostEnabled: Bool {
        didSet { UserDefaults.standard.set(midLineGhostEnabled, forKey: K.midLineGhostEnabled) }
    }

    let allowlist = AllowlistStore()
    let hudAnchors = HUDAnchorStore()
    let conversationTargets = ConversationTargetStore()
    let tones = ToneStore()
    let modelDownloads = ModelDownloadManager()
    let history = TypingHistoryStore()

    init() {
        let d = UserDefaults.standard
        self.enabled = (d.object(forKey: K.enabled) as? Bool) ?? true
        self.enrichmentEnabled = (d.object(forKey: K.enrichmentEnabled) as? Bool) ?? true
        self.captureEnabled = (d.object(forKey: K.captureEnabled) as? Bool) ?? false
        // Catalogue[0] is gemma-3-1b-pt-4bit (base, pretrained). User-tested
        // 2026-05-23: the IT/QAT variants are "smarter" on paper but
        // misbehave for inline autocomplete — they want to rewrite/correct
        // the user's text or echo back context fragments ("com.app.whisper"
        // loop). PT does pure next-token continuation which is exactly
        // what we want, even if it ignores the system prompt. Drift to
        // English (the original concern) is rare enough in practice;
        // anti-repeat post-process catches the worst of the IT failures
        // for the "test only" variants.
        self.modelID = (d.string(forKey: K.modelID)) ?? ModelOption.catalogue[0].id
        self.ggufModelID = (d.string(forKey: K.ggufModelID)) ?? GGUFModelOption.defaultID
        // Défaut français : l'app est français-first ; l'onboarding affine au 1ᵉʳ lancement.
        self.primaryLanguage = (d.string(forKey: K.primaryLanguage).flatMap(PrimaryLanguage.init(rawValue:))) ?? .french
        self.ocrLangFR = (d.object(forKey: K.ocrLangFR) as? Bool) ?? true
        self.ocrLangEN = (d.object(forKey: K.ocrLangEN) as? Bool) ?? true
        self.ocrLangES = (d.object(forKey: K.ocrLangES) as? Bool) ?? false
        self.typoEnabled = (d.object(forKey: K.typoEnabled) as? Bool) ?? true
        self.emojiEnabled = (d.object(forKey: K.emojiEnabled) as? Bool) ?? true
        self.completionLength = (d.string(forKey: K.completionLength).flatMap(CompletionLength.init(rawValue:))) ?? .medium
        self.hideOnTypo = (d.object(forKey: K.hideOnTypo) as? Bool) ?? true
        self.personalizationEnabled = (d.object(forKey: K.personalizationEnabled) as? Bool) ?? false
        self.personalizationStrength = (d.object(forKey: K.personalizationStrength) as? Double) ?? 1.0
        self.personalizationOnboardingShown = (d.object(forKey: K.personalizationOnboardingShown) as? Bool) ?? false
        // Prose capture defaults ON (the user keeps it on for a smarter ghost);
        // the now-wired toggle lets anyone disable it. The corpus stays bounded
        // (2k + dedup) and the prompt no longer gets random prose, so the
        // footprint is small. TO REVERT to opt-in: change `?? true` to `?? false`.
        self.storeWithoutAccepted = (d.object(forKey: K.storeWithoutAccepted) as? Bool) ?? true
        self.partialAcceptEnabled = (d.object(forKey: K.partialAcceptEnabled) as? Bool) ?? true
        self.acceptAllKey = AcceptAllKey(rawValue: d.string(forKey: K.acceptAllKey) ?? "") ?? .rightArrow
        self.commitKey = CommitKey(rawValue: d.string(forKey: K.commitKey) ?? "") ?? .cmdReturn
        self.translateHotKey = TranslateHotKeyOption(rawValue: d.string(forKey: K.translateHotKey) ?? "") ?? .optCmdT
        self.targetCycleKey = TargetCycleKey(rawValue: d.string(forKey: K.targetCycleKey) ?? "") ?? .cmdShiftRight
        self.translationModel = InstructModel(rawValue: d.string(forKey: K.translationModel) ?? "") ?? TranslationRuntime.defaultModel()
        self.trailingSpaceOnPartial = (d.object(forKey: K.trailingSpaceOnPartial) as? Bool) ?? true
        self.prefixCorrectionEnabled = (d.object(forKey: K.prefixCorrectionEnabled) as? Bool) ?? true
        self.midLineGhostEnabled = (d.object(forKey: K.midLineGhostEnabled) as? Bool) ?? false
    }

    /// Vision language codes derived from the toggles. Always non-empty (falls
    /// back to FR if the user deselects everything).
    var ocrLanguages: [String] {
        var langs: [String] = []
        if ocrLangFR { langs.append("fr-FR") }
        if ocrLangEN { langs.append("en-US") }
        if ocrLangES { langs.append("es-ES") }
        return langs.isEmpty ? ["fr-FR"] : langs
    }

    var currentModel: ModelOption {
        ModelOption.catalogue.first(where: { $0.id == modelID }) ?? ModelOption.catalogue[0]
    }

    /// The currently-selected GGUF entry (the real ghost engine model).
    var currentGGUFModel: GGUFModelOption {
        GGUFModelOption.option(forID: ggufModelID)
    }
}
