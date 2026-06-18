import CryptoKit
import Foundation
import Testing
@testable import Souffleuse
import SouffleuseCore

// MARK: - CompositeLicenseActivatorTests

/// Vérifie le routage du composite : un jeton auto-signé (Bitcoin/offline) part
/// vers la voie HORS LIGNE ; toute autre clé (Lemon Squeezy) vers la voie EN LIGNE.
/// Le tri se fait par la signature, jamais par le réseau.
@Suite("Composite license activator")
struct CompositeLicenseActivatorTests {

    /// Espion : retient la clé reçue, renvoie un identifiant d'instance distinctif.
    private actor SpyActivator: LicenseActivating {
        let tag: String
        private(set) var seenKey: String?
        init(tag: String) { self.tag = tag }
        func activate(key: String) async throws -> String? { seenKey = key; return tag }
        func deactivate(key: String, instanceId: String?) async throws { seenKey = key }
    }

    /// Génère une paire de test + un jeton signé pour `email`.
    private func freshKeypairAndToken(email: String) -> (pub: String, token: String) {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation.base64EncodedString()
        let token = LicenseKey.sign(email: email, privateKeyBase64: priv.rawRepresentation.base64EncodedString())!
        return (pub, token)
    }

    @Test("jeton signé valide → voie HORS LIGNE")
    func signedRoutesOffline() async throws {
        let (pub, token) = freshKeypairAndToken(email: "acheteur@exemple.fr")
        let offline = SpyActivator(tag: "offline")
        let online = SpyActivator(tag: "online")
        let composite = CompositeLicenseActivator(offline: offline, online: online, publicKeyBase64: pub)

        let instance = try await composite.activate(key: token)

        #expect(instance == "offline")
        #expect(await offline.seenKey == token)
        #expect(await online.seenKey == nil)
    }

    @Test("clé non signée (Lemon Squeezy) → voie EN LIGNE")
    func unsignedRoutesOnline() async throws {
        let (pub, _) = freshKeypairAndToken(email: "x@y.fr")
        let offline = SpyActivator(tag: "offline")
        let online = SpyActivator(tag: "online")
        let composite = CompositeLicenseActivator(offline: offline, online: online, publicKeyBase64: pub)

        let instance = try await composite.activate(key: "AAAA-BBBB-CCCC-DDDD")

        #expect(instance == "online")
        #expect(await online.seenKey == "AAAA-BBBB-CCCC-DDDD")
        #expect(await offline.seenKey == nil)
    }

    @Test("jeton signé par une AUTRE clé → traité comme en ligne (signature invalide ici)")
    func tokenFromOtherKeyRoutesOnline() async throws {
        // Jeton signé par une paire A, mais le composite connaît la clé publique B.
        let (_, tokenA) = freshKeypairAndToken(email: "a@a.fr")
        let (pubB, _) = freshKeypairAndToken(email: "b@b.fr")
        let offline = SpyActivator(tag: "offline")
        let online = SpyActivator(tag: "online")
        let composite = CompositeLicenseActivator(offline: offline, online: online, publicKeyBase64: pubB)

        let instance = try await composite.activate(key: tokenA)

        // Signature non valide pour pubB → pas reconnu comme jeton signé → en ligne.
        #expect(instance == "online")
    }

    @Test("deactivate route aussi par la forme du jeton")
    func deactivateRoutes() async throws {
        let (pub, token) = freshKeypairAndToken(email: "c@c.fr")
        let offline = SpyActivator(tag: "offline")
        let online = SpyActivator(tag: "online")
        let composite = CompositeLicenseActivator(offline: offline, online: online, publicKeyBase64: pub)

        try await composite.deactivate(key: token, instanceId: nil)

        #expect(await offline.seenKey == token)
        #expect(await online.seenKey == nil)
    }
}
