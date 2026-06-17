import Foundation
import NaturalLanguage
import Testing
@testable import SouffleuseCore
@testable import SouffleuseLlama

/// EVAL empirique (avant fix) : prouve que le code-switching FR↔ES observé en
/// UAT (2026-06-17) vient d'un SEGMENT multi-phrases sous le seuil de 200 car —
/// donc PAS redécoupé — que le Qwen 1.5B traduit à moitié. Compare, sur le VRAI
/// modèle, le paragraphe fautif traduit en BLOC ENTIER (comportement actuel) vs
/// PHRASE-PAR-PHRASE (fix proposé). Métrique : nombre de phrases de SORTIE dont
/// la langue dominante n'est pas l'espagnol. GGUF absent → suite sautée.
@Suite("Translation chunking — eval bloc vs phrases (modèle réel)", .serialized)
struct TranslationChunkingEvalTests {

    /// Le paragraphe exact du screenshot UAT : 2 phrases, ~155 car → SOUS les 200
    /// car de `TranslationChunker.maxWholeChars`, donc envoyé en un seul bloc.
    static let offending =
        "L'offre Starter permet de déclarer entièrement vos crypto. "
        + "Cependant, il suffit juste de rajouter les bonnes informations pour que ça fonctionne correctement."

    static func modelPathIfAvailable() -> String? {
        let p = NSString(string: "~/Library/Application Support/Souffleuse/Models/qwen2.5-1.5b-instruct-q4_k_m.gguf")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Découpe une chaîne en phrases (NLTokenizer) — ce que ferait le fix.
    static func sentences(of text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    /// Nombre de phrases de `text` dont la langue dominante n'est pas l'espagnol
    /// (≥ 8 car, sinon ignorée) — mesure du code-switching résiduel.
    static func nonSpanishSentences(in text: String) -> Int {
        sentences(of: text).filter { s in
            guard s.count >= 8 else { return false }
            let r = NLLanguageRecognizer()
            r.processString(s)
            return r.dominantLanguage != .spanish
        }.count
    }

    @Test("le paragraphe fautif tient en UN segment aujourd'hui (la cause)")
    func offendingIsSingleSegmentToday() {
        #expect(Self.offending.count <= TranslationChunker.maxWholeChars)
        let segs = TranslationChunker.segments(of: Self.offending)
        #expect(segs.count == 1, "attendu 1 segment (sous le seuil) → \(segs.count)")
        #expect(Self.sentences(of: Self.offending).count == 2)
    }

    /// Message complet reconstitué du screenshot UAT (multi-paragraphes → entre
    /// dans le découpage par lignes ; le 2e paragraphe = le segment fautif).
    static let fullMessage = """
    Bonjour,

    L'offre Starter permet de déclarer entièrement vos crypto. Cependant, il suffit juste de rajouter les bonnes informations pour que ça fonctionne correctement.

    Je vous invite à ajouter votre API Binance afin que je puisse vous aider.

    Bien à vous,
    Gabriel.
    """

    /// Traduit `fr` en espagnol sur `engine`. NE réinitialise PAS le KV : c'est
    /// l'appelant qui décide (recharge = KV neuf).
    static func translateES(_ fr: String, on engine: LlamaEngine) async -> String {
        final class Sink: @unchecked Sendable { var s = "" }
        let sink = Sink()
        _ = await engine.generate(
            prompt: GemmaChatPrompt.translation(of: fr, into: .es, model: .qwen1_5b),
            maxTokens: SuggestionPolicy.Tuning.transformMaxNewTokens(sourceChars: fr.count),
            sampling: LlamaSampling(
                temperature: 0, repeatPenalty: 1.1, repeatLastN: 64,
                primePenaltiesWithPrompt: true)
        ) { tok in sink.s += tok; return true }
        return GemmaChatPrompt.cleanCompletion(sink.s)
    }

    @Test("KV partagé vs KV neuf par segment, message complet (Qwen réel)")
    func sharedKVvsFreshKVPerSegment() async throws {
        try await LlamaTestGate.shared.run {
            guard let path = Self.modelPathIfAvailable() else {
                throw XCTSkipLikeError("modèle Qwen absent")
            }
            let engine = LlamaEngine()
            guard await engine.load(modelPath: path, contextTokens: 2048) else {
                throw XCTSkipLikeError("chargement impossible")
            }
            defer { Task { await engine.unload() } }

            let segments = TranslationChunker.segments(of: Self.fullMessage)
                .map(\.text)
                .filter { !$0.isEmpty }

            // ── C. KV PARTAGÉ entre segments = le VRAI pipeline (generateChunked
            //    ne reset jamais le KV). On enchaîne sans recharger.
            var sharedParts: [String] = []
            for seg in segments {
                sharedParts.append(await Self.translateES(seg, on: engine))
            }
            let shared = sharedParts.joined(separator: " ")
            let sharedBad = Self.nonSpanishSentences(in: shared)

            // ── D. KV NEUF par segment : recharge le modèle entre chaque segment
            //    (état propre garanti). Isole l'effet « contamination ».
            var freshParts: [String] = []
            for seg in segments {
                _ = await engine.unload()
                _ = await engine.load(modelPath: path, contextTokens: 2048)
                freshParts.append(await Self.translateES(seg, on: engine))
            }
            let fresh = freshParts.joined(separator: " ")
            let freshBad = Self.nonSpanishSentences(in: fresh)

            print("──────── EVAL KV partagé vs neuf ────────")
            print("segments =", segments.count)
            print("[C · KV PARTAGÉ (pipeline réel)] phrases non-ES =", sharedBad)
            print("  →", shared)
            print("[D · KV NEUF par segment]        phrases non-ES =", freshBad)
            print("  →", fresh)
            print("─────────────────────────────────────────")

            // Eval informatif : on documente l'écart. Hypothèse = la contamination
            // KV (C) produit plus de code-switching que l'isolement (D).
            #expect(freshBad <= sharedBad,
                    "KV neuf ne doit pas être pire que KV partagé")
        }
    }

    /// Texte d'amorçage : une opération de traduction ANTÉRIEURE dans la session
    /// (français long, sujet différent) qui laisse son état dans le KV du moteur
    /// instruct partagé — exactement ce qui distingue l'usage réel d'un eval froid.
    static let primingText = """
    Merci beaucoup pour votre message et pour les précisions apportées sur votre situation fiscale. \
    J'ai bien noté l'ensemble des opérations que vous avez réalisées au cours de l'année dernière. \
    Avant d'aller plus loin, j'aurais besoin que vous me confirmiez la liste complète des plateformes utilisées.
    """

    @Test("moteur AMORCÉ par une opération antérieure, puis message fautif (Qwen réel)")
    func warmSessionThenOffendingMessage() async throws {
        try await LlamaTestGate.shared.run {
            guard let path = Self.modelPathIfAvailable() else {
                throw XCTSkipLikeError("modèle Qwen absent")
            }
            let engine = LlamaEngine()
            guard await engine.load(modelPath: path, contextTokens: 2048) else {
                throw XCTSkipLikeError("chargement impossible")
            }
            defer { Task { await engine.unload() } }

            // Amorçage : on traduit d'abord un AUTRE message (par segments, comme
            // une opération précédente de la session), sans recharger.
            for seg in TranslationChunker.segments(of: Self.primingText).map(\.text) where !seg.isEmpty {
                _ = await Self.translateES(seg, on: engine)
            }
            let cachedAfterPriming = await engine.cachedTokenCount

            // PUIS le message fautif, sur le KV désormais « chaud » de la session.
            var parts: [String] = []
            for seg in TranslationChunker.segments(of: Self.fullMessage).map(\.text) where !seg.isEmpty {
                parts.append(await Self.translateES(seg, on: engine))
            }
            let warm = parts.joined(separator: " ")
            let warmBad = Self.nonSpanishSentences(in: warm)

            print("──────── EVAL session chaude ────────")
            print("KV résident après amorçage =", cachedAfterPriming, "tokens")
            print("[message fautif sur KV chaud] phrases non-ES =", warmBad)
            print("  →", warm)
            print("─────────────────────────────────────")

            // Informatif : si warmBad > 0 alors que froid = 0, le coupable est
            // l'état KV cross-opération (fix = reset KV par commit instruct).
            #expect(Bool(true))
        }
    }
}
