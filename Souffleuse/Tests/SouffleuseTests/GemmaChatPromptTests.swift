import Foundation
import Testing
@testable import SouffleuseCore

// MARK: - GemmaChatPromptTests

/// Garde le builder chat-template instruct de la traduction : forme des
/// marqueurs de tour Gemma, texte FR EN DERNIER (stabilité KV-cache LCP),
/// injection de la langue + des exemples de style, et la normalisation de
/// sortie. Pur — aucun modèle requis.
@Suite("GemmaChatPrompt")
struct GemmaChatPromptTests {

    @Test("le template enveloppe la consigne dans les marqueurs de tour Gemma")
    func turnMarkers() {
        let p = GemmaChatPrompt.translation(of: "Bonjour", into: .de)
        #expect(p.hasPrefix("<start_of_turn>user\n"))
        #expect(p.hasSuffix("<start_of_turn>model\n"))
        #expect(p.contains("<end_of_turn>\n<start_of_turn>model\n"))
    }

    @Test("le texte français est placé EN DERNIER (stabilité du préfixe KV-cache)")
    func frenchTextLast() {
        let p = GemmaChatPrompt.translation(of: "le wallet de 1 250,50 €", into: .en)
        let after = String(p[p.range(of: "Message : ")!.upperBound...])
        // Après « Message : » il ne reste que le texte FR + les marqueurs de clôture.
        #expect(after.hasPrefix("le wallet de 1 250,50 €"))
        #expect(after.contains("<end_of_turn>"))
    }

    @Test("le nom de la langue cible est injecté, grammatical")
    func languageNameInjected() {
        #expect(GemmaChatPrompt.translation(of: "x", into: .en).contains("vers l'anglais"))
        #expect(GemmaChatPrompt.translation(of: "x", into: .it).contains("vers l'italien"))
        #expect(GemmaChatPrompt.translation(of: "x", into: .ja).contains("vers le japonais"))
    }

    @Test("les exemples de style sont injectés AVANT le message")
    func examplesBeforeMessage() {
        let p = GemmaChatPrompt.translation(of: "msg", into: .es, examples: ["EXEMPLE_STYLE"])
        let exIdx = p.range(of: "EXEMPLE_STYLE")!.lowerBound
        let msgIdx = p.range(of: "Message :")!.lowerBound
        #expect(exIdx < msgIdx)
    }

    @Test("sans exemples, aucun bloc d'exemples n'est ajouté")
    func noExamplesNoBlock() {
        let p = GemmaChatPrompt.translation(of: "msg", into: .de)
        #expect(!p.contains("Exemples de mon style"))
    }

    @Test("cleanCompletion retire end_of_turn et les blancs")
    func cleanCompletion() {
        #expect(GemmaChatPrompt.cleanCompletion("  Hallo Welt<end_of_turn>\n") == "Hallo Welt")
        #expect(GemmaChatPrompt.cleanCompletion("Hallo Welt") == "Hallo Welt")
        #expect(GemmaChatPrompt.cleanCompletion("\n  Texte  \n") == "Texte")
    }

    @Test("le mapping de code de langue gère BCP-47 et l'inconnu")
    func languageCodeMapping() {
        #expect(TranslationTarget.from(languageCode: "de-DE") == .de)
        #expect(TranslationTarget.from(languageCode: "EN") == .en)
        #expect(TranslationTarget.from(languageCode: "es") == .es)
        #expect(TranslationTarget.from(languageCode: "ru") == nil)
    }

    @Test("JA est marqué hors V1, EN/ES/DE/IT en V1")
    func v1Scope() {
        #expect(TranslationTarget.ja.isV1 == false)
        #expect(TranslationTarget.en.isV1)
        #expect(TranslationTarget.es.isV1)
        #expect(TranslationTarget.de.isV1)
        #expect(TranslationTarget.it.isV1)
    }

    @Test("code expose le code langue en majuscules")
    func codeUppercased() {
        #expect(TranslationTarget.de.code == "DE")
        #expect(TranslationTarget.ja.code == "JA")
    }
}
