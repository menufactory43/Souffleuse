import Foundation
import NaturalLanguage

/// Découpe un message en segments de traduction de la taille où Qwen 1.5B
/// traduit FIDÈLEMENT (UAT 11/06 : au-delà de ~200 caractères, le modèle bascule
/// en « écho » du français à greedy — il recopie au lieu de traduire, malgré
/// few-shot et directive de langue ; chaque phrase isolée, elle, se traduit
/// proprement et avec une meilleure qualité).
///
/// Le découpage est en PHRASES (`NLTokenizer`, gère les abréviations FR), les
/// séparateurs d'origine (espaces, sauts de ligne) sont préservés dans `suffix`
/// pour réassembler la sortie avec la structure exacte du message. Pur,
/// déterministe, testable sans modèle.
public enum TranslationChunker {

    /// En-dessous de cette longueur, le message part en UN bloc (chemin
    /// historique, zéro changement pour les messages courts — le cas dominant).
    public static let maxWholeChars = 200

    /// Un segment à traduire + le séparateur d'origine qui le SUIT (réinjecté
    /// tel quel dans la sortie, jamais envoyé au modèle).
    public struct Segment: Sendable, Equatable {
        public let text: String
        public let suffix: String

        public init(text: String, suffix: String) {
            self.text = text
            self.suffix = suffix
        }
    }

    /// Segmente `text`. Court (≤ `maxWholeChars`) → un seul segment intégral.
    /// Long → une phrase par segment, séparateurs d'origine dans `suffix`.
    /// Invariant (testé) : la concaténation `text + suffix` des segments
    /// reconstitue l'entrée, blancs de tête exclus (l'appelant passe un texte
    /// déjà trimé).
    public static func segments(of text: String) -> [Segment] {
        guard text.count > maxWholeChars else {
            return [Segment(text: text, suffix: "")]
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        // Bornes de phrases re-trimées : NLTokenizer colle parfois le blanc
        // final (voire initial) au token — le modèle ne doit voir QUE la phrase.
        var sentenceRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var lo = range.lowerBound
            var hi = range.upperBound
            while lo < hi, text[lo].isWhitespace { lo = text.index(after: lo) }
            while hi > lo, text[text.index(before: hi)].isWhitespace { hi = text.index(before: hi) }
            if lo < hi { sentenceRanges.append(lo..<hi) }
            return true
        }
        guard sentenceRanges.count > 1 else {
            return [Segment(text: text, suffix: "")]
        }
        var result: [Segment] = []
        for (i, range) in sentenceRanges.enumerated() {
            let suffixEnd = i + 1 < sentenceRanges.count
                ? sentenceRanges[i + 1].lowerBound
                : text.endIndex
            result.append(Segment(
                text: String(text[range]),
                suffix: String(text[range.upperBound..<suffixEnd])))
        }
        return result
    }
}
