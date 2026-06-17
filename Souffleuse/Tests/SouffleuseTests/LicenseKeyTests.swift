import Testing
import Foundation
import CryptoKit
@testable import SouffleuseCore

/// Licences auto-signées Ed25519 : un aller-retour signer → vérifier doit passer,
/// toute altération (clé, email, mauvaise clé publique) doit échouer. Hors ligne.
@Suite("LicenseKey")
struct LicenseKeyTests {

    /// Paire de test fraîche (privée b64, publique b64).
    static func freshPair() -> (priv: String, pub: String) {
        let p = Curve25519.Signing.PrivateKey()
        return (p.rawRepresentation.base64EncodedString(), p.publicKey.rawRepresentation.base64EncodedString())
    }

    @Test("signer puis vérifier renvoie l'email (canonique)")
    func roundTrip() {
        let (priv, pub) = Self.freshPair()
        let key = LicenseKey.sign(email: "Gabriel@Souffleuse.app", privateKeyBase64: priv)
        #expect(key != nil)
        #expect(key!.hasPrefix("SOUF-"))
        // Email normalisé en minuscules.
        #expect(LicenseKey.verify(key!, publicKeyBase64: pub) == "gabriel@souffleuse.app")
    }

    @Test("clé altérée → invalide")
    func tamperedKeyFails() {
        let (priv, pub) = Self.freshPair()
        let key = LicenseKey.sign(email: "a@b.com", privateKeyBase64: priv)!
        // On flippe un caractère de la signature.
        let tampered = String(key.dropLast()) + (key.hasSuffix("A") ? "B" : "A")
        #expect(LicenseKey.verify(tampered, publicKeyBase64: pub) == nil)
    }

    @Test("vérif avec une AUTRE clé publique → invalide")
    func wrongPublicKeyFails() {
        let (priv, _) = Self.freshPair()
        let (_, otherPub) = Self.freshPair()
        let key = LicenseKey.sign(email: "a@b.com", privateKeyBase64: priv)!
        #expect(LicenseKey.verify(key, publicKeyBase64: otherPub) == nil)
    }

    @Test("formes invalides → decode nil")
    func malformedDecode() {
        #expect(LicenseKey.decode("pas-une-cle") == nil)
        #expect(LicenseKey.decode("SOUF-sansPoint") == nil)
        #expect(LicenseKey.decode("SOUF-@@@.@@@") == nil)
    }

    @Test("email rattaché : changer l'email casse la signature")
    func emailIsBoundToSignature() {
        let (priv, pub) = Self.freshPair()
        let key = LicenseKey.sign(email: "a@b.com", privateKeyBase64: priv)!
        guard let (_, sig) = LicenseKey.decode(key) else { Issue.record("decode"); return }
        // On ré-encode avec un AUTRE email mais la MÊME signature.
        let forged = LicenseKey.encode(email: "evil@x.com", signature: sig)
        #expect(LicenseKey.verify(forged, publicKeyBase64: pub) == nil)
    }
}
