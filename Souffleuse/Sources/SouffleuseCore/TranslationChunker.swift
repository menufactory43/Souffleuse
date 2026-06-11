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
    /// Long → découpage à DEUX niveaux :
    /// 1. les LIGNES d'abord — les sauts de ligne sont des séparateurs durs,
    ///    préservés dans `suffix` et JAMAIS envoyés au modèle (UAT 11/06,
    ///    Brave : « Bonjour Gabriel,\n\nMerci… » sans point = une seule
    ///    « phrase » pour NLTokenizer → le « \n\n » interne partait au modèle,
    ///    qui le mangeait en traduisant) ;
    /// 2. dans chaque ligne plus longue que `maxWholeChars`, les phrases.
    /// Invariant (testé) : la concaténation `text + suffix` des segments
    /// reconstitue l'entrée, blancs de tête exclus (l'appelant passe un texte
    /// déjà trimé).
    public static func segments(of text: String) -> [Segment] {
        guard text.count > maxWholeChars else {
            return [Segment(text: text, suffix: "")]
        }
        var result: [Segment] = []
        var index = text.startIndex
        while index < text.endIndex {
            // Contenu jusqu'au prochain « \n », puis la rafale de « \n » qui suit.
            var contentEnd = index
            while contentEnd < text.endIndex, text[contentEnd] != "\n" {
                contentEnd = text.index(after: contentEnd)
            }
            var gapEnd = contentEnd
            while gapEnd < text.endIndex, text[gapEnd] == "\n" {
                gapEnd = text.index(after: gapEnd)
            }
            let content = text[index..<contentEnd]
            let gap = String(text[contentEnd..<gapEnd])
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Ligne blanche (ou espaces seuls) → rattachée au suffixe du
                // segment précédent ; en tête de texte, perdue (entrée trimée).
                if var last = result.popLast() {
                    last = Segment(text: last.text, suffix: last.suffix + content + gap)
                    result.append(last)
                }
            } else {
                var lineSegments = sentenceSegments(of: content)
                // La rafale de « \n » suit le DERNIER segment de la ligne.
                if var last = lineSegments.popLast() {
                    last = Segment(text: last.text, suffix: last.suffix + gap)
                    lineSegments.append(last)
                }
                result.append(contentsOf: lineSegments)
            }
            index = gapEnd
        }
        return result.isEmpty ? [Segment(text: text, suffix: "")] : result
    }

    /// Niveau 2 : découpe une LIGNE (sans « \n ») en phrases si elle dépasse le
    /// cap ; sinon un segment unique. Les blancs entre phrases vont en `suffix`.
    private static func sentenceSegments(of line: Substring) -> [Segment] {
        let lineText = String(line)
        guard lineText.count > maxWholeChars else {
            return [Segment(text: lineText, suffix: "")]
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = lineText
        // Bornes de phrases re-trimées : NLTokenizer colle parfois le blanc
        // final (voire initial) au token — le modèle ne doit voir QUE la phrase.
        var sentenceRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: lineText.startIndex..<lineText.endIndex) { range, _ in
            var lo = range.lowerBound
            var hi = range.upperBound
            while lo < hi, lineText[lo].isWhitespace { lo = lineText.index(after: lo) }
            while hi > lo, lineText[lineText.index(before: hi)].isWhitespace { hi = lineText.index(before: hi) }
            if lo < hi { sentenceRanges.append(lo..<hi) }
            return true
        }
        guard sentenceRanges.count > 1 else {
            return [Segment(text: lineText, suffix: "")]
        }
        var result: [Segment] = []
        for (i, range) in sentenceRanges.enumerated() {
            let suffixEnd = i + 1 < sentenceRanges.count
                ? sentenceRanges[i + 1].lowerBound
                : lineText.endIndex
            result.append(Segment(
                text: String(lineText[range]),
                suffix: String(lineText[range.upperBound..<suffixEnd])))
        }
        return result
    }
}
