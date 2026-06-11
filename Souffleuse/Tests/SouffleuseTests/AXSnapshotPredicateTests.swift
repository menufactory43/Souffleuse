import Testing
import CoreGraphics
import SouffleuseAX

// MARK: - AXSnapshotPredicateTests

/// Garde les prédicats de classification de champ d'`AXSnapshot` : un champ de
/// RECHERCHE (subrole `AXSearchField`) est reconnu pour que la tick l'exclue du
/// ghost (pas de suggestion, pas de réveil du modèle), au même titre qu'un champ
/// sécurisé. Pur, sans AX réel.
@Suite("AXSnapshot field predicates")
struct AXSnapshotPredicateTests {

    private func snap(role: String?, subrole: String?) -> AXSnapshot {
        AXSnapshot(bundleID: "x", role: role, subrole: subrole, text: "",
                   caretIndex: 0, caretRect: nil, caretFont: nil)
    }

    @Test("subrole AXSearchField → isSearchField")
    func searchFieldDetected() {
        #expect(snap(role: "AXTextField", subrole: "AXSearchField").isSearchField)
    }

    @Test("un champ texte normal n'est pas une recherche")
    func plainTextFieldIsNotSearch() {
        #expect(snap(role: "AXTextArea", subrole: nil).isSearchField == false)
        #expect(snap(role: "AXTextField", subrole: nil).isSearchField == false)
    }

    @Test("recherche et secure sont distincts")
    func searchAndSecureAreDistinct() {
        let search = snap(role: "AXTextField", subrole: "AXSearchField")
        let secure = snap(role: "AXTextField", subrole: "AXSecureTextField")
        #expect(search.isSearchField && !search.isSecureField)
        #expect(secure.isSecureField && !secure.isSearchField)
    }

    // MARK: - isAddressBar (signatures sondées via axdump, 11/06/2026)

    private func snap(
        identifier: String? = nil,
        domIdentifier: String? = nil,
        domClassList: [String]? = nil
    ) -> AXSnapshot {
        AXSnapshot(bundleID: "x", role: "AXTextField", subrole: nil, text: "",
                   caretIndex: 0, caretRect: nil, caretFont: nil,
                   identifier: identifier, domIdentifier: domIdentifier,
                   domClassList: domClassList)
    }

    @Test("omnibox Safari : AXIdentifier dédié")
    func safariOmniboxDetected() {
        #expect(snap(identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD").isAddressBar)
    }

    @Test("omnibox Chromium : classe Views, Chrome nu et forks")
    func chromiumOmniboxDetected() {
        #expect(snap(domClassList: ["OmniboxViewViews"]).isAddressBar)
        #expect(snap(domClassList: ["BraveOmniboxViewViews"]).isAddressBar)
    }

    @Test("barre d'adresse Firefox : AXDOMIdentifier urlbar-input")
    func firefoxUrlbarDetected() {
        #expect(snap(domIdentifier: "urlbar-input").isAddressBar)
    }

    @Test("un AXIdentifier quelconque ne matche pas (Notes : Note Body Text View)")
    func unrelatedIdentifierIsNotAddressBar() {
        #expect(snap(identifier: "Note Body Text View").isAddressBar == false)
        #expect(snap().isAddressBar == false)
    }

    @Test("classe DOM d'une page web quelconque ne matche pas")
    func pageDomClassIsNotAddressBar() {
        #expect(snap(domClassList: ["download-button", "mdc-button"]).isAddressBar == false)
    }

    // MARK: - isPickerField (sondé sur un chip-input Angular Material, 11/06/2026)

    private func snap(hasPopup: Bool = false, autocompleteKind: String? = nil) -> AXSnapshot {
        AXSnapshot(bundleID: "x", role: "AXComboBox", subrole: nil, text: "",
                   caretIndex: 0, caretRect: nil, caretFont: nil,
                   hasPopup: hasPopup, autocompleteKind: autocompleteKind)
    }

    @Test("aria-haspopup → sélecteur")
    func hasPopupIsPicker() {
        #expect(snap(hasPopup: true).isPickerField)
    }

    @Test("aria-autocomplete list/both → sélecteur")
    func autocompleteListIsPicker() {
        #expect(snap(autocompleteKind: "list").isPickerField)
        #expect(snap(autocompleteKind: "both").isPickerField)
    }

    @Test("autocomplete inline/none ou absent → pas un sélecteur")
    func inlineAutocompleteIsNotPicker() {
        #expect(snap(autocompleteKind: "inline").isPickerField == false)
        #expect(snap(autocompleteKind: "none").isPickerField == false)
        #expect(snap().isPickerField == false)
    }
}

// MARK: - RemapBlockCaretTests

/// Garde le remap du caret Chromium multi-blocs (Linear/ProseMirror dans
/// Brave, repro 11/06/2026) : l'hôte rapporte un offset SANS les séparateurs
/// de blocs alors que l'AXValue insère un "\n" par bloc — fin de texte lue
/// comme mid-line, préfixe amputé. Valeurs des repros contenteditable.
@Suite("AXClient.remapBlockCaret")
struct RemapBlockCaretTests {

    @Test("sans newline : identité")
    func identityWithoutNewline() {
        #expect(AXClient.remapBlockCaret(text: "abcdef", reported: 3) == 3)
        #expect(AXClient.remapBlockCaret(text: "abcdef", reported: 6) == 6)
    }

    @Test("repro 2 paragraphes : fin de texte rapportée len-1 → len")
    func twoParagraphEndOfText() {
        let text = "Premiere ligne deja ecrite avant\nNot sure you can help but i will"
        // 65 chars dont 1 newline ; Brave rapportait caret=64.
        #expect(AXClient.remapBlockCaret(text: text, reported: 64) == text.count)
    }

    @Test("repro 3 paragraphes : fin de texte rapportée len-2 → len")
    func threeParagraphEndOfText() {
        let text = "Premiere ligne\nDeuxieme ligne\nNot sure you can help but i will"
        // 62 chars dont 2 newlines ; Brave rapportait caret=60.
        #expect(AXClient.remapBlockCaret(text: text, reported: 60) == text.count)
    }

    @Test("caret au milieu d'un paragraphe suivant : décalé du nb de blocs amont")
    func midParagraphCaret() {
        let text = "Premiere ligne\nDeuxieme"
        // Caret réel après "Deux" (index 19) ; l'hôte rapporte 18 (1 bloc avant).
        #expect(AXClient.remapBlockCaret(text: text, reported: 18) == 19)
    }

    @Test("frontière de bloc : le caret se place AVANT le newline (fin de ligne)")
    func blockBoundaryStaysEndOfLine() {
        let text = "Premiere ligne\nDeuxieme"
        // 14 non-newline consommés pile à la frontière → index 14 (avant "\n").
        #expect(AXClient.remapBlockCaret(text: text, reported: 14) == 14)
    }

    @Test("offset au-delà du texte : clampé à la fin")
    func overshootClampsToEnd() {
        #expect(AXClient.remapBlockCaret(text: "ab\ncd", reported: 99) == 5)
    }
}
