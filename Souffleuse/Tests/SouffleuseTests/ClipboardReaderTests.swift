import Testing
import Foundation
import AppKit
import SouffleuseContext

/// Couvre la blocklist du presse-papier ET la posture **fail-closed** sur
/// bundleID inconnu : sans app focus identifiée, on n'a aucun moyen d'appliquer
/// la blocklist, donc on s'abstient de lire (jamais de fuite par défaut).
@Suite("ClipboardReader — blocklist + fail-closed sur bundleID nil")
struct ClipboardReaderTests {

    private func reader(_ content: String, blocklist: [String] = ClipboardReader.defaultBlocklist) -> ClipboardReader {
        // Pasteboard nommé isolé (ne touche pas le presse-papier système).
        let pb = NSPasteboard(name: NSPasteboard.Name("souffleuse-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(content, forType: .string)
        return ClipboardReader(pasteboard: pb, blocklist: blocklist)
    }

    @Test("app normale : la prose du presse-papier est retournée")
    func normalAppReadsClipboard() async {
        let r = reader("Voici le texte que je viens de copier")
        let out = await r.read(frontmostBundleID: "com.brave.Browser")
        #expect(out == "Voici le texte que je viens de copier")
    }

    @Test("app blocklistée : presse-papier jamais lu")
    func blockedAppReturnsNil() async {
        let r = reader("mon-mot-de-passe-secret")
        let out = await r.read(frontmostBundleID: "com.1password.1password")
        #expect(out == nil)
    }

    @Test("fail-closed : bundleID nil ⇒ presse-papier non lu (pas de blocklist applicable)")
    func nilBundleFailsClosed() async {
        let r = reader("contenu sensible potentiel")
        let out = await r.read(frontmostBundleID: nil)
        #expect(out == nil)   // avant le fix : lisait le presse-papier (fail-open)
    }
}
