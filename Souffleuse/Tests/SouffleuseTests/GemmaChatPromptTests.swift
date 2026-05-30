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

    // MARK: - Multi-modèles (Gemma vs Qwen ChatML)

    @Test("modèle par défaut = Gemma (sortie inchangée)")
    func defaultModelIsGemma() {
        let withDefault = GemmaChatPrompt.translation(of: "Bonjour", into: .de)
        let explicit = GemmaChatPrompt.translation(of: "Bonjour", into: .de, model: .gemma1b)
        #expect(withDefault == explicit)
    }

    @Test("Qwen utilise le chat-template ChatML (system + user + assistant)")
    func qwenChatMLTemplate() {
        let p = GemmaChatPrompt.translation(of: "le wallet de 1 250,50 €", into: .en, model: .qwen1_5b)
        #expect(p.hasPrefix("<|im_start|>system\n"))
        #expect(p.hasSuffix("<|im_start|>assistant\n"))
        #expect(p.contains("<|im_end|>\n<|im_start|>user\n"))
        // La consigne de fidélité est dans le système ; le message dans le user.
        #expect(p.contains("traducteur professionnel"))
        #expect(p.contains("<|im_start|>user\nle wallet de 1 250,50 €<|im_end|>"))
        // Aucun marqueur Gemma.
        #expect(!p.contains("<start_of_turn>"))
    }

    @Test("cleanCompletion gère aussi le token de fin Qwen")
    func cleanHandlesQwenStop() {
        #expect(GemmaChatPrompt.cleanCompletion("  Hello world<|im_end|>") == "Hello world")
        #expect(GemmaChatPrompt.cleanCompletion("Hello<|endoftext|> extra") == "Hello")
        // Tronque à la PREMIÈRE balise rencontrée, peu importe la famille.
        #expect(GemmaChatPrompt.cleanCompletion("A<|im_end|>B<end_of_turn>C") == "A")
    }

    @Test("chaque modèle expose son GGUF et un libellé")
    func instructModelMetadata() {
        #expect(InstructModel.gemma1b.ggufFilename == "gemma-3-1b-it-Q4_K_M.gguf")
        #expect(InstructModel.qwen1_5b.ggufFilename == "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        #expect(InstructModel.allCases.count == 2)
        #expect(!InstructModel.qwen1_5b.displayName.isEmpty)
    }

    // MARK: - Relecture FR→FR (reformulation)

    @Test("la relecture Gemma enveloppe la consigne et place le message EN DERNIER")
    func reformulationGemmaTurnMarkers() {
        let p = GemmaChatPrompt.reformulation(of: "slt ça va le wallet", tone: .neutral)
        #expect(p.hasPrefix("<start_of_turn>user\n"))
        #expect(p.hasSuffix("<start_of_turn>model\n"))
        let after = String(p[p.range(of: "Message : ")!.upperBound...])
        #expect(after.hasPrefix("slt ça va le wallet"))
        #expect(after.contains("<end_of_turn>"))
    }

    @Test("la consigne de relecture réécrit (ne traduit pas) et garde les entités dures")
    func reformulationInstructionContent() {
        let p = GemmaChatPrompt.reformulation(of: "x", tone: .neutral)
        #expect(p.contains("Réécris EN FRANÇAIS"))
        #expect(p.contains("correcteur-rédacteur"))
        #expect(!p.contains("traducteur professionnel"))  // surtout PAS de traduction
        #expect(p.contains("noms propres, montants"))
    }

    @Test("chaque ton injecte son registre")
    func reformulationToneFragment() {
        #expect(GemmaChatPrompt.reformulation(of: "x", tone: .casual).contains("tutoiement"))
        #expect(GemmaChatPrompt.reformulation(of: "x", tone: .neutral).contains("neutre"))
        #expect(GemmaChatPrompt.reformulation(of: "x", tone: .formal).contains("vouvoiement"))
    }

    @Test("la relecture Qwen utilise ChatML (consigne système, message user)")
    func reformulationQwenChatML() {
        let p = GemmaChatPrompt.reformulation(of: "le wallet", tone: .formal, model: .qwen1_5b)
        #expect(p.hasPrefix("<|im_start|>system\n"))
        #expect(p.hasSuffix("<|im_start|>assistant\n"))
        #expect(p.contains("<|im_start|>user\nle wallet<|im_end|>"))
        #expect(p.contains("vouvoiement"))
        #expect(!p.contains("<start_of_turn>"))
    }

    @Test("les exemples de style sont injectés AVANT le message en relecture")
    func reformulationExamplesBeforeMessage() {
        let p = GemmaChatPrompt.reformulation(of: "msg", tone: .neutral, examples: ["EXEMPLE_STYLE"])
        #expect(p.range(of: "EXEMPLE_STYLE")!.lowerBound < p.range(of: "Message :")!.lowerBound)
    }

    @Test("la traduction reste intacte (registre traducteur, pas de relecture)")
    func translationStillTranslates() {
        let p = GemmaChatPrompt.translation(of: "Bonjour", into: .de)
        #expect(p.contains("traducteur professionnel"))
        #expect(!p.contains("Réécris EN FRANÇAIS"))
    }
}
