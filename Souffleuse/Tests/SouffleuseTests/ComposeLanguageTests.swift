import Testing
@testable import SouffleuseCore

/// Préférence de langue du mode rédaction « // ». Pur — mapping de codes et
/// noms de langue injectés dans la consigne, aucun store ni UI.
@Suite("ComposeLanguage")
struct ComposeLanguageTests {

    @Test("langues figées → nom FR sans article pour la consigne")
    func fixedLanguagesPromptName() {
        #expect(ComposeLanguage.french.promptLanguageName == "français")
        #expect(ComposeLanguage.english.promptLanguageName == "anglais")
        #expect(ComposeLanguage.spanish.promptLanguageName == "espagnol")
        #expect(ComposeLanguage.german.promptLanguageName == "allemand")
        #expect(ComposeLanguage.italian.promptLanguageName == "italien")
    }

    @Test("« suivre la conversation » n'a pas de nom figé (résolu par l'appelant)")
    func conversationHasNoFixedName() {
        #expect(ComposeLanguage.conversation.promptLanguageName == nil)
    }

    @Test("repli système : code BCP-47 → langue supportée, sinon français")
    func systemFallbackMapping() {
        #expect(ComposeLanguage.fallbackName(systemCode: "fr") == "français")
        #expect(ComposeLanguage.fallbackName(systemCode: "en-US") == "anglais")
        #expect(ComposeLanguage.fallbackName(systemCode: "es-ES") == "espagnol")
        #expect(ComposeLanguage.fallbackName(systemCode: "de") == "allemand")
        #expect(ComposeLanguage.fallbackName(systemCode: "it-IT") == "italien")
        // Hors périmètre (portugais, japonais…) → français : la 1B n'écrit
        // proprement que le périmètre supporté.
        #expect(ComposeLanguage.fallbackName(systemCode: "pt-BR") == "français")
        #expect(ComposeLanguage.fallbackName(systemCode: "ja") == "français")
    }

    @Test("rangées composables : 5 langues concrètes, sans « suivre la conversation »")
    func composableRows() {
        #expect(ComposeLanguage.composable == [.french, .english, .spanish, .german, .italian])
        #expect(!ComposeLanguage.composable.contains(.conversation))
    }

    @Test("mapping cible de traduction → langue de rédaction (JA hors périmètre → FR)")
    func fromTranslationTarget() {
        #expect(ComposeLanguage.from(target: .en) == .english)
        #expect(ComposeLanguage.from(target: .es) == .spanish)
        #expect(ComposeLanguage.from(target: .de) == .german)
        #expect(ComposeLanguage.from(target: .it) == .italian)
        #expect(ComposeLanguage.from(target: .ja) == .french)
    }

    @Test("repli système concret : code → langue composable, sinon français")
    func systemFallbackConcrete() {
        #expect(ComposeLanguage.fallback(systemCode: "en-GB") == .english)
        #expect(ComposeLanguage.fallback(systemCode: "it") == .italian)
        #expect(ComposeLanguage.fallback(systemCode: "pt-BR") == .french)
        // Cohérence nom ↔ case.
        #expect(ComposeLanguage.fallback(systemCode: "de").promptLanguageName == "allemand")
    }

    @Test("raw value stable (persistence UserDefaults) et CaseIterable complet")
    func rawValueAndCases() {
        #expect(ComposeLanguage(rawValue: "conversation") == .conversation)
        #expect(ComposeLanguage(rawValue: "french") == .french)
        #expect(ComposeLanguage(rawValue: "inconnu") == nil)
        // Le menu présente : conversation + français + les 4 cibles V1.
        #expect(ComposeLanguage.allCases == [.conversation, .french, .english, .spanish, .german, .italian])
    }
}
