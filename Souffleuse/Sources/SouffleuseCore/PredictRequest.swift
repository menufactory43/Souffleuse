import Foundation

// MARK: - PredictRequest

/// Predict request — value-type capture of all inputs flowing from PVM into
/// the LLM pipeline.
///
/// **Phase 5 (SouffleuseCore extraction)** : déplacé VERBATIM depuis
/// `ModelRuntime.swift` (target `Souffleuse`). `ModelRuntime.generate(...)`
/// continue de le consommer via l'import de `SouffleuseCore`.
public struct PredictRequest: Sendable {
    public let prefix: String
    public let contextPrefix: String
    public let customInstructions: String
    public let axSnapshotPlaceholder: String?
    public let axSnapshotHelp: String?
    public let axSnapshotRole: String?
    public let axSnapshotSubrole: String?
    public let axTextAfterCaret: String?
    public let personalizationStrength: Double
    /// Préférence « Teinter les suggestions » (Préférences > Personnalisation) :
    /// active le bias corpus du beam (et le style primer côté PVM) sans variable
    /// d'env. Les flags dev `SOUFFLEUSE_BEAM_BIAS` / `SOUFFLEUSE_STYLE_PRIMER`
    /// restent des overrides (OU logique). Snapshot par requête — aucun état
    /// partagé avec `ModelRuntime` (non isolé).
    public let personalizedSuggestions: Bool
    public let maxTokens: Int
    public let maxWords: Int
    public let detectedLanguage: String?
    public let token: GenerationToken

    /// Trimmed user text actually fed to the LLM (suffix 2048 cap).
    /// Identical to the legacy `userTail`.
    public let userTail: String
    /// Cap-512 suffix of `userTail` — the textual content actually
    /// included in the user-message of the chat template.
    public let llmTail: String
    /// True if the active model id contains `-it` or `instruct`.
    public let isInstructModel: Bool
    /// Full legacy system message (base + customInstructions + contextPrefix).
    public let systemMessage: String
    /// Base framing only, used by the new PromptBuilder path.
    public let baseSystem: String
    /// Trimmed custom instructions slot body.
    public let customInstr: String
    /// Trimmed context prefix slot body.
    public let ctxPrefix: String
    /// Field context slot body assembled from AX snapshot (FR prose).
    public let fieldContextSlot: String
    /// After-cursor slot body assembled from AX snapshot (FR prose).
    public let afterCursorSlot: String
    /// Soft preamble fed into base/PT prompt (customInstr + ctxPrefix
    /// joined by blank lines, with trailing "\n\n" if non-empty).
    public let basePreamble: String
    /// Few-shot examples block (similarity-ranked, prebuilt by caller
    /// via `await TypingHistoryStore.similarEntries(...)`).
    public let examplesBlock: String
    /// Full assembled prompt text for the base/PT path
    /// (`basePreamble + examplesBlock + llmTail`).
    public let basePromptText: String

    public init(
        prefix: String,
        contextPrefix: String,
        customInstructions: String,
        axSnapshotPlaceholder: String?,
        axSnapshotHelp: String?,
        axSnapshotRole: String?,
        axSnapshotSubrole: String?,
        axTextAfterCaret: String?,
        personalizationStrength: Double,
        personalizedSuggestions: Bool = false,
        maxTokens: Int,
        maxWords: Int,
        detectedLanguage: String?,
        token: GenerationToken,
        userTail: String,
        llmTail: String,
        isInstructModel: Bool,
        systemMessage: String,
        baseSystem: String,
        customInstr: String,
        ctxPrefix: String,
        fieldContextSlot: String,
        afterCursorSlot: String,
        basePreamble: String,
        examplesBlock: String,
        basePromptText: String
    ) {
        self.prefix = prefix
        self.contextPrefix = contextPrefix
        self.customInstructions = customInstructions
        self.axSnapshotPlaceholder = axSnapshotPlaceholder
        self.axSnapshotHelp = axSnapshotHelp
        self.axSnapshotRole = axSnapshotRole
        self.axSnapshotSubrole = axSnapshotSubrole
        self.axTextAfterCaret = axTextAfterCaret
        self.personalizationStrength = personalizationStrength
        self.personalizedSuggestions = personalizedSuggestions
        self.maxTokens = maxTokens
        self.maxWords = maxWords
        self.detectedLanguage = detectedLanguage
        self.token = token
        self.userTail = userTail
        self.llmTail = llmTail
        self.isInstructModel = isInstructModel
        self.systemMessage = systemMessage
        self.baseSystem = baseSystem
        self.customInstr = customInstr
        self.ctxPrefix = ctxPrefix
        self.fieldContextSlot = fieldContextSlot
        self.afterCursorSlot = afterCursorSlot
        self.basePreamble = basePreamble
        self.examplesBlock = examplesBlock
        self.basePromptText = basePromptText
    }
}
