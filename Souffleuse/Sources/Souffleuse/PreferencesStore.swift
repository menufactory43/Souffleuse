import Foundation
import Observation
import SouffleusePersonalization

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

    /// Token cap fed to GenerateParameters. The sentence-end truncation in
    /// onChunk will still chop early if the model emits `.`, `?`, `!`.
    ///
    /// `.medium = 4` matches the Cotypist Free default and aligns with the
    /// "~2-4 mots" label (SentencePiece FR ≈ 2-3 mots for 4 tokens). The
    /// short cap is critical for perceived speed: every token saved is
    /// ~12-20ms shaved off total stream time, which directly reduces the
    /// cancel-on-keystroke race window.
    var maxTokens: Int {
        switch self {
        case .short: return 3
        case .medium: return 4
        case .long: return 20
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
        static let partialAcceptEnabled = "partialAcceptEnabled"
        static let trailingSpaceOnPartial = "trailingSpaceOnPartial"
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
    var personalizationOnboardingShown: Bool {
        didSet { UserDefaults.standard.set(personalizationOnboardingShown, forKey: K.personalizationOnboardingShown) }
    }
    /// When true, Tab on an LLM suggestion accepts only the next word (with
    /// optional trailing space). The remainder stays in the ghost; Tab again
    /// accepts the next word. Cotypist-style. Default on.
    var partialAcceptEnabled: Bool {
        didSet { UserDefaults.standard.set(partialAcceptEnabled, forKey: K.partialAcceptEnabled) }
    }
    /// When true, partial accept includes the single space following the
    /// accepted word/punctuation so the caret lands ready for the next word.
    /// Default on.
    var trailingSpaceOnPartial: Bool {
        didSet { UserDefaults.standard.set(trailingSpaceOnPartial, forKey: K.trailingSpaceOnPartial) }
    }

    let allowlist = AllowlistStore()
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
        self.partialAcceptEnabled = (d.object(forKey: K.partialAcceptEnabled) as? Bool) ?? true
        self.trailingSpaceOnPartial = (d.object(forKey: K.trailingSpaceOnPartial) as? Bool) ?? true
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
}
