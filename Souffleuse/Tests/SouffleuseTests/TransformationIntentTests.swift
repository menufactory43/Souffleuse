import Foundation
import Testing
@testable import SouffleuseCore

// MARK: - TransformationIntentTests

/// Garde le matching filtre → intention du picker « // » : préfixes, pliage
/// casse/accents, ordre stable des rangées, non-match → instruction libre.
/// Pur — aucune UI, aucun store.
@Suite("TransformationIntent matching")
struct TransformationIntentTests {

    @Test("filtre vide → les 5 intentions, dans l'ordre du picker")
    func emptyFilterReturnsAll() {
        #expect(TransformationIntent.matches(filter: "") == TransformationIntent.pickerOrder)
        #expect(TransformationIntent.pickerOrder ==
            [.corriger, .raccourcir, .reformuler, .ton, .traduire])
    }

    @Test("préfixes distinctifs → une seule rangée chacun")
    func distinctivePrefixes() {
        #expect(TransformationIntent.matches(filter: "cor") == [.corriger])
        #expect(TransformationIntent.matches(filter: "rac") == [.raccourcir])
        #expect(TransformationIntent.matches(filter: "ref") == [.reformuler])
        #expect(TransformationIntent.matches(filter: "ton") == [.ton])
        #expect(TransformationIntent.matches(filter: "tra") == [.traduire])
    }

    @Test("insensible à la casse")
    func caseInsensitive() {
        #expect(TransformationIntent.matches(filter: "COR") == [.corriger])
        #expect(TransformationIntent.matches(filter: "Rac") == [.raccourcir])
    }

    @Test("insensible aux accents (réf, tôn)")
    func diacriticInsensitive() {
        #expect(TransformationIntent.matches(filter: "réf") == [.reformuler])
        #expect(TransformationIntent.matches(filter: "tôn") == [.ton])
    }

    @Test("préfixe partagé « r » → raccourcir puis reformuler, ordre du picker")
    func sharedPrefixKeepsPickerOrder() {
        #expect(TransformationIntent.matches(filter: "r") == [.raccourcir, .reformuler])
    }

    @Test("préfixe partagé « t » → ton puis traduire")
    func sharedPrefixT() {
        #expect(TransformationIntent.matches(filter: "t") == [.ton, .traduire])
    }

    @Test("aucun match → tableau vide (l'appelant bascule en .libre au ⏎)")
    func noMatchIsEmpty() {
        #expect(TransformationIntent.matches(filter: "rends ça plus poli").isEmpty)
        #expect(TransformationIntent.matches(filter: "xyz").isEmpty)
    }

    @Test("espaces parasites autour du filtre tolérés")
    func surroundingWhitespaceTolerated() {
        #expect(TransformationIntent.matches(filter: " cor ") == [.corriger])
    }

    @Test("match complet exact, mais pas au-delà du libellé")
    func exactMatchButNotBeyond() {
        #expect(TransformationIntent.matches(filter: "corriger") == [.corriger])
        #expect(TransformationIntent.matches(filter: "corrigera").isEmpty)
    }

    @Test("displayName français pour chaque rangée + l'instruction libre")
    func displayNames() {
        #expect(TransformationIntent.corriger.displayName == "corriger")
        #expect(TransformationIntent.raccourcir.displayName == "raccourcir")
        #expect(TransformationIntent.reformuler.displayName == "reformuler")
        #expect(TransformationIntent.ton.displayName == "ton")
        #expect(TransformationIntent.traduire.displayName == "traduire")
        #expect(TransformationIntent.libre("x").displayName == "instruction libre")
        #expect(TransformationIntent.rediger(.french).displayName == "rédiger · français")
        #expect(TransformationIntent.rediger(.english).displayName == "rédiger · anglais")
    }

    @Test(".rediger porte sa langue et reste Equatable")
    func redigerCarriesLanguage() {
        #expect(TransformationIntent.rediger(.spanish) == .rediger(.spanish))
        #expect(TransformationIntent.rediger(.spanish) != .rediger(.german))
        #expect(TransformationIntent.rediger(.french) != .corriger)
    }

    @Test(".rediger n'est pas une rangée fixe du picker (mode composition)")
    func redigerIsNotInPickerOrder() {
        #expect(!TransformationIntent.pickerOrder.contains(.rediger(.french)))
        // Aucun filtre ne doit faire matcher .rediger (il est hors des rangées).
        #expect(!TransformationIntent.matches(filter: "réd").contains(.rediger(.french)))
    }

    @Test(".libre porte son instruction et reste Equatable")
    func libreCarriesInstruction() {
        #expect(TransformationIntent.libre("plus poli") == .libre("plus poli"))
        #expect(TransformationIntent.libre("plus poli") != .libre("plus court"))
        #expect(TransformationIntent.libre("x") != .corriger)
    }

    @Test("TextTransformation est Equatable et porte ses champs")
    func textTransformationFields() {
        let t = TextTransformation(
            scopeText: "Bonjour", intent: .corriger,
            isScopeTruncated: true, deleteCharsOnAccept: 12)
        #expect(t.scopeText == "Bonjour")
        #expect(t.intent == .corriger)
        #expect(t.isScopeTruncated)
        #expect(t.deleteCharsOnAccept == 12)
        #expect(t == TextTransformation(
            scopeText: "Bonjour", intent: .corriger,
            isScopeTruncated: true, deleteCharsOnAccept: 12))
    }
}
