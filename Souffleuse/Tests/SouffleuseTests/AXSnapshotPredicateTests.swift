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
}
