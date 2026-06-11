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
}
