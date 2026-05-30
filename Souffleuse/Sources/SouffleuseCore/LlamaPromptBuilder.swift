import Foundation
import NaturalLanguage

// MARK: - LlamaPromptBuilder (pure prompt assembly + language detection)

/// Pure helpers for assembling the llama.cpp prompt string and the system
/// framing, plus prefix language detection.
///
/// **Phase 5 (SouffleuseCore extraction)** : déplacé VERBATIM depuis
/// `ModelRuntime` (target `Souffleuse`). `ModelRuntime` conserve des shims
/// `static func` qui délèguent ici, donc tous les call-sites
/// `ModelRuntime.buildLlamaPrompt(...)`, `ModelRuntime.buildSystemPrompt(...)`,
/// `ModelRuntime.detectLanguage(...)` (PVM + tests) compilent inchangés.
public enum LlamaPromptBuilder {

    /// Mid-word confidence gate threshold (Cotypist `minBranchProbability`
    /// parity). DISABLED (0): the probe calibration (2026-05-27) showed the
    /// first-token softmax probability does NOT separate good mid-word
    /// completions from bad ones — the model is often confidently WRONG
    /// ("informations pe"→"peinardes" at p=0.41 while the user meant
    /// "personnelles"), so no threshold discriminates. The `firstTokenProb`
    /// metric + the gate mechanism are kept (cheap, dormant at 0) for possible
    /// reuse, but the mid-word fix is architectural (route mid-word to the
    /// word-completer/history, not free LLM), not a confidence threshold.
    public static let midWordMinFirstTokenProb: Float = 0

    /// Default autocomplete framing used in the system message of chat-template
    /// models.
    public static let autocompleteSystemPrompt = """
    You are an inline autocomplete inside the user's text field. Continue the user's text exactly where it stops, in the SAME language and style as the user. Output ONLY the continuation — never repeat the user's text, never add greetings, explanations, or quotes. Keep it short: a few words, one short sentence at most. If the text ends mid-word, complete that word first. If it ends after a space, predict the next words. Output plain text only: NEVER use Markdown, HTML, XML, bold, italics, code fences, or any formatting tags like <b>, **, _, ``. Just the raw characters the user would have typed themselves.
    """

    /// Builds a system prompt with an explicit language-steering header
    /// when we confidently detected the prefix's language.
    public static func buildSystemPrompt(detectedLanguage: String?) -> String {
        guard let lang = detectedLanguage else { return autocompleteSystemPrompt }
        return """
        The user is currently writing in \(lang). You MUST output the continuation in \(lang) only — never switch languages, never translate, never output English when the user is writing in \(lang).

        \(autocompleteSystemPrompt)
        """
    }

    /// Detects the dominant language of the last ~512 chars of the prefix.
    /// Returns the language as an English name ("French", "Spanish", …).
    public static func detectLanguage(in text: String) -> String? {
        let tail = String(text.suffix(512))
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[lang], confidence < 0.5 { return nil }

        switch lang {
        case .french: return "French"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .simplifiedChinese, .traditionalChinese: return "Chinese"
        case .arabic: return "Arabic"
        case .turkish: return "Turkish"
        default:
            return Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue)
        }
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
    /// `Contexte :` PROSE block, never as a command.
    public static func buildLlamaPrompt(
        system: String,
        customInstr: String,
        ctxPrefix: String,
        fieldContext: String,
        afterCursor: String,
        beforeCursor: String,
        examples: String = ""
    ) -> String {
        var prefix = ""
        let trimmedInstr = customInstr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstr.isEmpty { prefix += "Contexte : " + trimmedInstr + "\n\n" }
        // Few-shot prose injection (B-prompt, 2026-05-30). The retrieved block is
        // the user's OWN past prose (SimilarHistoryRetrieval, `.prose` only). The
        // injection-eval (SouffleuseInjectionEval) showed the RAW block anchors the
        // base model to the user's register/domain and suppresses off-topic
        // hallucination ("Certains frais mal" → A: news-article derail; B: "frais
        // à payer"), with NO multi-greeting cross-pollution at this corpus size —
        // the failure that motivated PVM:600-609's removal did not reproduce. Kept
        // raw (no "Exemples:" label) per SimilarHistoryRetrieval's rationale: a PT
        // base model imitates labels. Placed in the ctxPrefix position; beforeCursor
        // stays strictly last so the continuation still extends the caret text.
        let trimmedExamples = examples.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExamples.isEmpty { prefix += trimmedExamples + "\n\n" }
        if !ctxPrefix.isEmpty { prefix += ctxPrefix + "\n\n" }
        if !fieldContext.isEmpty { prefix += fieldContext + "\n\n" }
        // Strip a TRAILING space/tab from the text the model continues. A
        // SentencePiece model emits the next token WITH its own leading space
        // (" arriver"), so a space already present at the end derails greedy —
        // "on va y " loops/repeats, while "on va y" cleanly yields " arriver.".
        // Newlines are NOT trimmed — a caret on a fresh line is intentional.
        var bc = beforeCursor
        while let last = bc.last, last == " " || last == "\t" { bc.removeLast() }
        return prefix + bc
    }
}
