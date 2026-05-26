import Testing
import Foundation
@testable import SouffleusePrompt

// PromptBuilder en isolation totale de MLX. Mock `TokenCounting` co-located
// per pattern `MockOCRCaretLocator` dans `CaretResolverTests.swift`. Snapshot
// + invariants (D-04 per-slot independence, D-11 never mid-word /
// sentence-preferred, determinism).

// MARK: - Test doubles

/// Deterministic mock: counts tokens as whitespace-separated words.
/// Truncation: drop words from the head until count ≤ budget. Word-count
/// proxy est suffisant pour exercer l'eviction logic sans charger MLX.
/// Le vrai tokenizer est exercé par le replay harness (plan 01-04) et
/// validé via human eyeball, pas snapshot equality (R3).
struct WordCountTokenCounter: TokenCounting {
    func countTokens(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        guard budget >= 1 else { return "" }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > budget else { return text }
        // Drop words from head until ≤ budget. NEVER mid-word — on opère
        // sur des whole-word boundaries par construction.
        return words.suffix(budget).joined(separator: " ")
    }
}

/// Mock plus strict qui exerce sentence-boundary preference (D-11 step (a)).
/// Quand un sentence terminator (. / ? / !) en queue de mot sit dans le
/// budget, head-truncate au plus petit cut qui atterrit sur une frontière
/// de phrase. Sinon fallback word-boundary truncation.
struct SentenceAwareTokenCounter: TokenCounting {
    func countTokens(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    func truncateHead(_ text: String, toBudget budget: Int) -> String {
        guard budget >= 1 else { return "" }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > budget else { return text }
        // Scan pour un terminateur de phrase : si on coupe juste après ce
        // mot, le reste doit être ≤ budget. Prefer le plus petit cut
        // (= plus de contexte retenu).
        let terminators: [Character] = [".", "?", "!"]
        for cutWordIdx in 0..<(words.count - budget) {
            if let lastChar = words[cutWordIdx].last, terminators.contains(lastChar) {
                let remaining = words.suffix(words.count - cutWordIdx - 1)
                if remaining.count <= budget {
                    return remaining.joined(separator: " ")
                }
            }
        }
        // Fallback : word boundary (suffix de budget mots).
        return words.suffix(budget).joined(separator: " ")
    }
}

// MARK: - Tests

@Test func builderAssemblesAllSlotsInOrder() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase1Default)
    let built = builder.build(
        system: "You are an inline autocomplete.",
        customInstructions: "Be concise.",
        contextPrefix: "App Slack window equipe.",
        previousUserInputs: "Hello team how is it going",
        beforeCursor: "Bonjour, je voulais vous dire"
    )
    let expected = """
You are an inline autocomplete.

Be concise.

App Slack window equipe.

Hello team how is it going

Bonjour, je voulais vous dire
"""
    #expect(built.text == expected)
    #expect(built.truncatedSlots.isEmpty)
}

@Test func builderHandlesEmptySlotsWithoutBlankLines() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let built = builder.build(
        system: "Sys",
        customInstructions: "",
        contextPrefix: "",
        previousUserInputs: "",
        beforeCursor: "User text"
    )
    // Slots vides ne contribuent rien — pas de blank lines superflues.
    #expect(built.text == "Sys\n\nUser text")
    #expect(built.slotTexts.count == 2)
    #expect(built.slotTexts[.system] == "Sys")
    #expect(built.slotTexts[.beforeCursor] == "User text")
}

@Test func builderTruncatesBeforeCursorAtWordBoundary() {
    let counter = WordCountTokenCounter()
    // beforeCursor budget = 3 mots ; input = 5 mots ; head-truncated to last 3.
    let budget = PromptBudget(global: 100, perSlot: [.beforeCursor: 3])
    let builder = PromptBuilder(counter: counter, budget: budget)
    let text = "Salutations bienveillantes mon ami fidèle"
    let built = builder.build(
        system: "", customInstructions: "", contextPrefix: "", previousUserInputs: "",
        beforeCursor: text
    )
    #expect(built.text == "mon ami fidèle")
    #expect(built.truncatedSlots.contains(.beforeCursor))
    #expect(built.slotTexts[.beforeCursor] == "mon ami fidèle")
}

@Test func builderNeverCutsMidWord() {
    // Invariant D-11(c) : la sortie commence TOUJOURS par un caractère de
    // mot, jamais au milieu d'un mot. Avec WordCountTokenCounter c'est
    // garanti par construction (split sur whitespace). Le test verrouille
    // l'invariant contre toute future regression.
    let counter = WordCountTokenCounter()
    let budget = PromptBudget(global: 100, perSlot: [.beforeCursor: 2])
    let builder = PromptBuilder(counter: counter, budget: budget)
    let text = "Premier deuxième troisième quatrième cinquième"
    let built = builder.build(
        system: "", customInstructions: "", contextPrefix: "", previousUserInputs: "",
        beforeCursor: text
    )
    let first = built.text.first
    #expect(first != nil)
    if let first {
        #expect(first.isLetter || first.isNumber)
    }
    #expect(built.text == "quatrième cinquième")
}

@Test func builderPrefersSentenceBoundaryOverWordBoundary() {
    // D-11 step (a) > step (b) : si une frontière de phrase rentre dans le
    // budget, c'est elle qui est choisie. SentenceAwareTokenCounter encode
    // cette préférence ; le builder délègue à `counter.truncateHead`.
    let counter = SentenceAwareTokenCounter()
    let budget = PromptBudget(global: 100, perSlot: [.beforeCursor: 6])
    let builder = PromptBuilder(counter: counter, budget: budget)
    let longTail = "First sentence is here. Second sentence is here. Third short."
    let built = builder.build(
        system: "", customInstructions: "", contextPrefix: "", previousUserInputs: "",
        beforeCursor: longTail
    )
    // Invariants génériques : la sortie est tronquée, commence par un mot
    // complet, ≤ 6 mots, et est un suffixe (preserves the tail per D-11).
    let words = built.text.split(whereSeparator: { $0.isWhitespace })
    #expect(words.count <= 6)
    #expect(built.truncatedSlots.contains(.beforeCursor))
    #expect(longTail.hasSuffix(built.text))
    if let first = built.text.first {
        #expect(first.isLetter || first.isNumber)
    }
}

@Test func builderHonorsPerSlotBudgetsIndependently() {
    // D-04 : pas de cross-slot stealing. Si contextPrefix fit dans son budget
    // de 5 mais beforeCursor overflows son budget de 3, SEUL beforeCursor est
    // tronqué.
    let counter = WordCountTokenCounter()
    let budget = PromptBudget(
        global: 1000,
        perSlot: [
            .contextPrefix: 5,
            .beforeCursor: 3,
        ]
    )
    let builder = PromptBuilder(counter: counter, budget: budget)
    let built = builder.build(
        system: "",
        customInstructions: "",
        contextPrefix: "one two three four five",   // exactement 5 mots, fit
        previousUserInputs: "",
        beforeCursor: "alpha beta gamma delta epsilon"  // 5 mots, overflow budget 3
    )
    #expect(!built.truncatedSlots.contains(.contextPrefix))
    #expect(built.truncatedSlots.contains(.beforeCursor))
    #expect(built.slotTexts[.contextPrefix] == "one two three four five")
    #expect(built.slotTexts[.beforeCursor] == "gamma delta epsilon")
}

@Test func builderIsDeterministic() {
    // 100 invocations sur les mêmes inputs doivent produire des BuiltPrompt
    // Equatable-equal. Catche les régressions de nondéterminisme (Set iter,
    // dictionary ordering, etc.).
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let first = builder.build(
        system: "s", customInstructions: "c", contextPrefix: "p", previousUserInputs: "f",
        beforeCursor: "b"
    )
    for _ in 0..<99 {
        let again = builder.build(
            system: "s", customInstructions: "c", contextPrefix: "p", previousUserInputs: "f",
            beforeCursor: "b"
        )
        #expect(again == first)
    }
}

@Test func builderRecordsTokenCountsPerSlot() {
    // BuiltPrompt.slotTokenCounts doit être peuplé post-eviction et sa
    // somme doit égaler totalTokens.
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let built = builder.build(
        system: "one two",              // 2
        customInstructions: "",
        contextPrefix: "three",          // 1
        previousUserInputs: "",
        beforeCursor: "four five six"    // 3
    )
    #expect(built.slotTokenCounts[.system] == 2)
    #expect(built.slotTokenCounts[.contextPrefix] == 1)
    #expect(built.slotTokenCounts[.beforeCursor] == 3)
    #expect(built.slotTokenCounts[.customInstructions] == nil)
    #expect(built.slotTokenCounts[.previousUserInputs] == nil)
    #expect(built.totalTokens == 6)
}

@Test func builderReservedPhase2SlotsAreNotFilled() {
    // PromptSlot déclare 4 slots reserved Phase 3 (afterCursor, fieldContext,
    // clipboardContext, screenContext). En Phase 2, `build(...)` n'expose pas
    // de paramètres pour eux et slotTexts ne doit jamais les contenir.
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter)
    let built = builder.build(
        system: "s", customInstructions: "c", contextPrefix: "p", previousUserInputs: "f",
        beforeCursor: "b"
    )
    let reservedSlots: [PromptSlot] = [
        .afterCursor, .fieldContext,
        .clipboardContext, .screenContext,
    ]
    for slot in reservedSlots {
        #expect(built.slotTexts[slot] == nil)
        #expect(built.slotTokenCounts[slot] == nil)
        #expect(!built.truncatedSlots.contains(slot))
    }
}

@Test func builderHonorsGlobalCapViaEvictionPriority() {
    // Global cap fires : sum per-slot tokens > global. Selon evictionPriority
    // (previousUserInputs first → customInstructions → contextPrefix →
    // beforeCursor → system), le slot previousUserInputs est droppé en premier.
    let counter = WordCountTokenCounter()
    let budget = PromptBudget(
        global: 5,  // très serré
        perSlot: [
            .system: 10,
            .customInstructions: 10,
            .contextPrefix: 10,
            .previousUserInputs: 10,
            .beforeCursor: 10,
        ]
    )
    let builder = PromptBuilder(counter: counter, budget: budget)
    let built = builder.build(
        system: "one two",                  // 2
        customInstructions: "three",        // 1
        contextPrefix: "four",              // 1
        previousUserInputs: "five six seven", // 3
        beforeCursor: "eight"               // 1
    )
    // Total per-slot : 2+1+1+3+1 = 8 > 5 → eviction.
    // previousUserInputs droppé en premier (3 mots) → reste 5, fit.
    #expect(built.totalTokens <= 5)
    #expect(built.truncatedSlots.contains(.previousUserInputs))
    #expect(built.slotTexts[.previousUserInputs] == nil)
    // Les autres slots restent intacts.
    #expect(built.slotTexts[.system] == "one two")
    #expect(built.slotTexts[.customInstructions] == "three")
    #expect(built.slotTexts[.contextPrefix] == "four")
    #expect(built.slotTexts[.beforeCursor] == "eight")
}

// MARK: - Phase 2 slot tests

@Test func builderEmitsFieldContextSlotWhenSupplied() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "Tu es un autocomplete.",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "Champ : recherche.\nPlaceholder : « Rechercher dans la conversation… ».",
        afterCursor: "",
        previousUserInputs: "",
        beforeCursor: "Hello"
    )
    #expect(built.text.contains("Champ : recherche."))
    #expect(built.text.contains("Placeholder : « Rechercher dans la conversation… »."))
    #expect(built.slotTexts[.fieldContext] != nil)
}

@Test func builderEmitsAfterCursorBeforeBeforeCursor() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "",
        afterCursor: "Suite du texte (à ne pas répéter) : « apres ».",
        previousUserInputs: "",
        beforeCursor: "avant"
    )
    let afterIdx = built.text.range(of: "Suite du texte")!.lowerBound
    let beforeIdx = built.text.range(of: "avant")!.lowerBound
    #expect(afterIdx < beforeIdx, "afterCursor must precede beforeCursor in the assembled prompt (D-14b)")
}

@Test func builderSkipsEmptyFieldContextAndAfterCursor() {
    let counter = WordCountTokenCounter()
    let builder = PromptBuilder(counter: counter, budget: .phase2Default)
    let built = builder.build(
        system: "S",
        customInstructions: "",
        contextPrefix: "",
        fieldContext: "",     // D-14c / D-15: skip if empty
        afterCursor: "",      // D-14c
        previousUserInputs: "",
        beforeCursor: "B"
    )
    // No empty headers, no triple blank-line runs.
    #expect(!built.text.contains("\n\n\n"))
    #expect(built.slotTexts[.fieldContext] == nil)
    #expect(built.slotTexts[.afterCursor] == nil)
    #expect(built.slotTokenCounts[.fieldContext] == nil)
    #expect(built.slotTokenCounts[.afterCursor] == nil)
}

@Test func builderEvictsPreviousUserInputsFirstUnderTightGlobalCap() {
    // Force eviction by setting a tight global cap. The lowest-priority slot
    // (previousUserInputs, per Phase 2 evictionPriority head) must drop first.
    let tight = PromptBudget(
        global: 10,
        perSlot: [
            .system: 4,
            .customInstructions: 4,
            .contextPrefix: 4,
            .fieldContext: 4,
            .afterCursor: 4,
            .previousUserInputs: 4,
            .beforeCursor: 4,
        ]
    )
    let builder = PromptBuilder(counter: WordCountTokenCounter(), budget: tight)
    let built = builder.build(
        system: "a b c d",
        customInstructions: "e f g h",
        contextPrefix: "i j k l",
        fieldContext: "m n o p",
        afterCursor: "q r s t",
        previousUserInputs: "u v w x",
        beforeCursor: "y z"
    )
    #expect(built.truncatedSlots.contains(.previousUserInputs),
            "previousUserInputs must be the first slot evicted under global-cap pressure (Phase 2 evictionPriority head)")
    #expect(built.slotTexts[.previousUserInputs] == nil,
            "Eviction in this builder is a drop (not partial squeeze) for non-beforeCursor slots")
}

@Test func roleLabelFRPrefersSubroleOverRole() {
    // Subrole AXSearchField is more specific than role AXTextField; helper must pick subrole.
    let label = PromptBuilder.roleLabelFR(role: "AXTextField", subrole: "AXSearchField")
    #expect(label == "recherche")
    // Falls back to role when subrole is nil.
    let labelRoleOnly = PromptBuilder.roleLabelFR(role: "AXTextArea", subrole: nil)
    #expect(labelRoleOnly == "zone de texte")
    // Returns nil when neither mapping is known.
    let unmapped = PromptBuilder.roleLabelFR(role: "AXUnknownThing", subrole: nil)
    #expect(unmapped == nil)
}
