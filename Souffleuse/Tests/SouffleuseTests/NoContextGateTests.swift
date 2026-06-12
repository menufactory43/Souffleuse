import Testing
import Foundation
import SouffleuseCore

/// Phase 1 (KeyType ghost engine) — garde lexicale « pas de contexte ⇒ pas de
/// ghost » + enum de raisons typées. Pure-function, aucun runtime LLM requis.
///
/// La garde existe pour tuer les ghosts « fortune cookie » : sur un préfixe
/// sans mot de contenu, un base model part dans ses priors d'ouverture. On
/// vérifie qu'elle distingue un vrai signal lexical d'un préfixe creux
/// (vide / blanc / ponctuation / stop-words / chiffres seuls).
@Suite("Phase 1 — No-context lexical gate")
struct NoContextGateTests {

    @Test("Préfixe avec ≥1 mot de contenu → a du contexte")
    func realContentPasses() {
        #expect(SuggestionPolicy.hasLexicalContext("Je te confirme notre rendez-vous"))
        #expect(SuggestionPolicy.hasLexicalContext("rapport fiscal"))
        // Un seul mot de contenu suffit au seuil par défaut (min: 1).
        #expect(SuggestionPolicy.hasLexicalContext("Bonjour Géraldine"))
    }

    @Test("Préfixe creux → pas de contexte")
    func hollowPrefixesFail() {
        #expect(!SuggestionPolicy.hasLexicalContext(""))
        #expect(!SuggestionPolicy.hasLexicalContext("   \n\t "))
        #expect(!SuggestionPolicy.hasLexicalContext("... !!! ?"))
        // Chiffres seuls : pas de lettres → aucun mot de contenu.
        #expect(!SuggestionPolicy.hasLexicalContext("12 34 567"))
        // Uniquement des stop-words / mots <2 lettres.
        #expect(!SuggestionPolicy.hasLexicalContext("je ne le"))
        #expect(!SuggestionPolicy.hasLexicalContext("the to of"))
    }

    @Test("Seuil min configurable")
    func minThreshold() {
        // « rapport » = 1 mot de contenu ("fiscal" en a 1 aussi → 2 au total).
        #expect(SuggestionPolicy.hasLexicalContext("rapport fiscal", min: 2))
        #expect(!SuggestionPolicy.hasLexicalContext("rapport", min: 2))
        // min <= 0 → toujours vrai (garde désactivée).
        #expect(SuggestionPolicy.hasLexicalContext("", min: 0))
    }

    @Test("Raisons de suppression : rawValues stables et distincts")
    func suppressionReasonRawValues() {
        let all = CompletionSuppressionReason.allCases
        // rawValues uniques (clé de jointure fiable en agrégat).
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(CompletionSuppressionReason.noLexicalContext.rawValue == "noLexicalContext")
        #expect(CompletionSuppressionReason.midWordDeadEnd.rawValue == "midWordDeadEnd")
    }
}
