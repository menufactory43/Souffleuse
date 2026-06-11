import Foundation
import NaturalLanguage
import Testing
@testable import SouffleuseCore
@testable import SouffleuseLlama

/// Régression UAT 11/06 : « //traduire » FR→ES ressortait le FRANÇAIS corrigé
/// au lieu de l'espagnol. Cause : le ring de pénalité de répétition n'était
/// jamais amorcé avec la queue du prompt — l'écho du message source n'était
/// pas pénalisé et l'emportait à greedy (llama-completion, qui amorce, sort
/// bien de l'espagnol sur le prompt byte-identique). Fix :
/// `LlamaSampling.primePenaltiesWithPrompt` (opt-in, activé par les trois flux
/// instruct de `TranslationRuntime` ; le ghost reste byte-identique).
/// Modèle réel requis (Qwen 2.5 1.5B instruct) ; absent → suite sautée.
/// `.serialized` : un seul contexte llama.cpp à la fois (backend Metal global).
@Suite("Transformations « // » — bascule de consigne sur moteur chaud", .serialized)
struct TransformPromptSwitchTests {

    static let userParagraph = """
    La plus value est encore descendue, il manque encore des transactions \
    cependant pour un rapport cohérent. J'ai vu un retrait que vous aviez \
    surement un compte BlockFI. Est t'il possible d'avoir un fichier de ces \
    transactions ?
    """

    static func modelPathIfAvailable() -> String? {
        let p = NSString(string: "~/Library/Application Support/Souffleuse/Models/qwen2.5-1.5b-instruct-q4_k_m.gguf")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Même sampling et budget que `TranslationRuntime.transform` en prod.
    static func gen(_ engine: LlamaEngine, _ prompt: String) async -> String {
        final class Sink: @unchecked Sendable { var s = "" }
        let sink = Sink()
        let budget = SuggestionPolicy.Tuning.transformMaxNewTokens(sourceChars: userParagraph.count)
        _ = await engine.generate(
            prompt: prompt,
            maxTokens: budget,
            sampling: LlamaSampling(
                temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                primePenaltiesWithPrompt: true)
        ) { tok in sink.s += tok; return true }
        return GemmaChatPrompt.cleanCompletion(sink.s)
    }

    static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    @Test("contrôle : traduction FR→ES sur moteur froid sort de l'espagnol")
    func coldTranslationIsSpanish() async throws {
        try await LlamaTestGate.shared.run {
            guard let path = Self.modelPathIfAvailable() else {
                throw XCTSkipLikeError("modèle Qwen absent")
            }
            let engine = LlamaEngine()
            guard await engine.load(modelPath: path, contextTokens: 2048) else {
                throw XCTSkipLikeError("chargement du modèle impossible")
            }
            let prompt = GemmaChatPrompt.translation(of: Self.userParagraph, into: .es, model: .qwen1_5b)
            let out = await Self.gen(engine, prompt)
            #expect(Self.dominantLanguage(of: out) == .spanish, "sortie contrôle : \(out)")
            await engine.unload()
        }
    }

    @Test("« //corriger » puis « //traduire » : la traduction reste de l'espagnol")
    func warmCorrectionThenTranslationIsStillSpanish() async throws {
        try await LlamaTestGate.shared.run {
            guard let path = Self.modelPathIfAvailable() else {
                throw XCTSkipLikeError("modèle Qwen absent")
            }
            let engine = LlamaEngine()
            guard await engine.load(modelPath: path, contextTokens: 2048) else {
                throw XCTSkipLikeError("chargement du modèle impossible")
            }
            // Génération 1 : correction (remplit le KV avec la consigne correcteur).
            let correction = await Self.gen(
                engine, GemmaChatPrompt.correction(of: Self.userParagraph, model: .qwen1_5b))
            #expect(Self.dominantLanguage(of: correction) == .french, "correction : \(correction)")
            // Génération 2 : traduction ES sur le MÊME moteur (KV chaud). Le préfixe
            // commun des deux system prompts ne doit PAS contaminer la consigne.
            let translation = await Self.gen(
                engine, GemmaChatPrompt.translation(of: Self.userParagraph, into: .es, model: .qwen1_5b))
            #expect(Self.dominantLanguage(of: translation) == .spanish, "traduction chaude : \(translation)")
            await engine.unload()
        }
    }
}
