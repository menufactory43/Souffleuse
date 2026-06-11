import Foundation
import NaturalLanguage
import Testing
@testable import SouffleuseCore
@testable import SouffleuseLlama

/// Découpage phrase-par-phrase des traductions longues (UAT 11/06 : au-delà de
/// ~200 caractères, Qwen 1.5B « échote » le français à greedy au lieu de
/// traduire — chaque phrase isolée se traduit proprement).
@Suite("TranslationChunker — segmentation")
struct TranslationChunkerTests {

    static let waltioText = """
    C'est normal : en Waltio, on ne choisit pas "EUR" comme token. Pour une \
    vente d'ETH en euro, tu crées une opération de type Échange, et tu remplis \
    2 lignes : la crypto vendue (ETH) et la crypto reçue (l'autre crypto).
    Donc si tu as vendu ETH contre des euros, tu mettras quand même ETH dans \
    le champ token, puis tu choisis le token reçu (par exemple USDC, USDT, \
    etc., selon ce que la plateforme a crédité).
    Quel token as-tu reçu après la vente d'ETH (USDC, USDT, ou autre) ?
    """

    @Test("texte court → un seul segment intégral (chemin historique intact)")
    func shortTextSingleSegment() {
        let text = "Bonjour, pouvez-vous vérifier mon export ?"
        let segs = TranslationChunker.segments(of: text)
        #expect(segs == [TranslationChunker.Segment(text: text, suffix: "")])
        // À la limite exacte du cap : toujours un bloc.
        let atCap = String(repeating: "a", count: TranslationChunker.maxWholeChars)
        #expect(TranslationChunker.segments(of: atCap).count == 1)
    }

    @Test("texte long → une phrase par segment, sans blanc en bord de segment")
    func longTextSplitsPerSentence() {
        let segs = TranslationChunker.segments(of: Self.waltioText)
        #expect(segs.count >= 4)
        for seg in segs {
            #expect(!seg.text.isEmpty)
            #expect(seg.text == seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test("invariant : concat(text + suffix) reconstitue l'entrée")
    func reassemblyInvariant() {
        let rebuilt = TranslationChunker.segments(of: Self.waltioText)
            .map { $0.text + $0.suffix }
            .joined()
        #expect(rebuilt == Self.waltioText)
    }

    @Test("les sauts de ligne survivent dans les suffixes")
    func newlinesPreservedInSuffixes() {
        let suffixes = TranslationChunker.segments(of: Self.waltioText).map(\.suffix)
        #expect(suffixes.contains { $0.contains("\n") })
    }

    @Test("la ligne vide entre paragraphes survit — salutation sans point isolée")
    func blankLineBetweenParagraphsSurvives() {
        // UAT 11/06 (Brave) : « Bonjour Gabriel,\n\nMerci… » sans point = une
        // seule « phrase » pour NLTokenizer → le \n\n partait DANS le segment
        // et le modèle le mangeait. Les lignes sont désormais des séparateurs
        // durs : la salutation est isolée, le \n\n vit dans son suffixe.
        let body = String(
            repeating: "Merci pour votre retour et pour le temps consacré à mon dossier. ",
            count: 4
        ).trimmingCharacters(in: .whitespaces)
        let text = "Bonjour Gabriel,\n\n" + body
        let segs = TranslationChunker.segments(of: text)
        #expect(segs.first?.text == "Bonjour Gabriel,")
        #expect(segs.first?.suffix == "\n\n")
        #expect(segs.map { $0.text + $0.suffix }.joined() == text)
        // La structure n'est JAMAIS confiée au modèle : aucun segment ne
        // contient de saut de ligne.
        #expect(segs.allSatisfy { !$0.text.contains("\n") })
    }

    @Test("texte long SANS frontière de phrase → un seul segment (pas de coupe arbitraire)")
    func longTextWithoutSentenceBoundary() {
        let text = String(repeating: "mot ", count: 80).trimmingCharacters(in: .whitespaces)
        let segs = TranslationChunker.segments(of: text)
        #expect(segs.count == 1)
        #expect(segs[0].text == text)
    }
}

/// Régression modèle-réel (UAT 11/06, 2e rapport) : chaque segment du texte
/// Waltio doit se traduire en ESPAGNOL — c'est l'hypothèse sur laquelle repose
/// le découpage de `TranslationRuntime.translate`. Le texte ENTIER, lui,
/// échouait (écho français) même avec few-shot + directive. GGUF absent →
/// suite sautée. `.serialized` : un contexte llama.cpp à la fois.
@Suite("TranslationChunker — segments × modèle réel", .serialized)
struct TranslationChunkerModelTests {

    static func modelPathIfAvailable() -> String? {
        let p = NSString(string: "~/Library/Application Support/Souffleuse/Models/qwen2.5-1.5b-instruct-q4_k_m.gguf")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    @Test("chaque segment du texte Waltio part en espagnol (pas d'écho)")
    func everySegmentTranslatesToSpanish() async throws {
        try await LlamaTestGate.shared.run {
            guard let path = Self.modelPathIfAvailable() else {
                throw XCTSkipLikeError("modèle Qwen absent")
            }
            let engine = LlamaEngine()
            guard await engine.load(modelPath: path, contextTokens: 2048) else {
                throw XCTSkipLikeError("chargement impossible")
            }
            for segment in TranslationChunker.segments(of: TranslationChunkerTests.waltioText) {
                final class Sink: @unchecked Sendable { var s = "" }
                let sink = Sink()
                _ = await engine.generate(
                    prompt: GemmaChatPrompt.translation(of: segment.text, into: .es, model: .qwen1_5b),
                    maxTokens: SuggestionPolicy.Tuning.translationMaxNewTokens(sourceChars: segment.text.count),
                    sampling: LlamaSampling(
                        temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                        primePenaltiesWithPrompt: true)
                ) { tok in sink.s += tok; return true }
                let out = GemmaChatPrompt.cleanCompletion(sink.s)
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(out)
                #expect(recognizer.dominantLanguage == .spanish, "segment « \(segment.text.prefix(40)) » : \(out)")
            }
            await engine.unload()
        }
    }
}
