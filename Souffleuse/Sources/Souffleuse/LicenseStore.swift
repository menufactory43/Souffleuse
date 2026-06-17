import Foundation
import Observation
import Security
import SouffleuseCore
import SouffleuseLog

/// **Kill switch GLOBAL du paywall.** `false` (défaut) → `isPro` est TOUJOURS
/// vrai : tout Souffleuse Studio est déverrouillé, le gating dort, rien ne change
/// pour personne. Passe-le à `true` pour activer le mur (licence requise pour les
/// features Studio) ; repasse-le à `false` pour **revert instantanément**. C'est
/// une constante compile-time : un flip = un rebuild, aucune migration, aucune
/// donnée touchée.
enum LicenseGate {
    static let paywallEnabled = false

    /// URL d'achat (Lemon Squeezy) — placeholder tant que le produit n'existe pas.
    static let purchaseURL = URL(string: "https://souffleuse.app/studio")!

    /// Clé PUBLIQUE Ed25519 (base64 raw) qui vérifie les licences signées, hors
    /// ligne. ⚠️ Paire de DÉV pour l'instant — en prod, régénère une paire avec
    /// `swift run SouffleuseLicenseGen genkeys`, colle la PUBLIQUE ici, et garde la
    /// PRIVÉE secrète (c'est elle qui signe ce que tu vends).
    static let publicKeyBase64 = "tfdPVUpavMpqzZ/ot13LjekSl//OyXI5pCgpiQnXqR8="
}

/// Erreurs d'activation, avec message FR/EN prêt pour l'UI.
enum LicenseError: Error, Equatable {
    case empty
    case invalidKey
    case network
    case deviceLimitReached

    var message: String {
        switch self {
        case .empty: return tr(fr: "Saisis ta clé de licence.", en: "Enter your license key.")
        case .invalidKey: return tr(fr: "Clé invalide ou inconnue.", en: "Invalid or unknown key.")
        case .network: return tr(fr: "Activation impossible — vérifie ta connexion.", en: "Activation failed — check your connection.")
        case .deviceLimitReached: return tr(fr: "Cette licence est déjà utilisée sur le nombre maximal d'appareils.", en: "This license is already used on the maximum number of devices.")
        }
    }
}

/// Frontière d'activation (le SEUL moment réseau). Stubbée tant que le produit
/// Lemon Squeezy n'existe pas ; à remplacer par un `LemonSqueezyActivator` qui
/// appelle l'endpoint `/v1/licenses/activate`. Isolée derrière un protocole pour
/// rester testable sans réseau.
protocol LicenseActivating: Sendable {
    /// Réussit silencieusement si la clé est valide, throw `LicenseError` sinon.
    func activate(key: String) async throws
}

/// Stub de dev (placeholder) : accepte une clé non vide préfixée « SOUF- », sans
/// vérifier la signature. Conservé pour les TESTS qui n'embarquent pas de clé.
struct StubLicenseActivator: LicenseActivating {
    func activate(key: String) async throws {
        guard key.hasPrefix("SOUF-"), key.count >= 10 else { throw LicenseError.invalidKey }
    }
}

/// Activateur RÉEL : vérifie la signature Ed25519 de la clé avec la clé publique
/// embarquée — **hors ligne, zéro réseau**. C'est le pendant in-app du générateur
/// `SouffleuseLicenseGen`. Remplace le stub par défaut.
struct SignedLicenseActivator: LicenseActivating {
    func activate(key: String) async throws {
        guard LicenseKey.verify(key, publicKeyBase64: LicenseGate.publicKeyBase64) != nil else {
            throw LicenseError.invalidKey
        }
    }
}

/// Licence « Studio » (achat unique). L'activation fait UN appel réseau (délégué
/// à `LicenseActivating`), puis le résultat est mis en cache LOCALEMENT (Keychain,
/// device-only) — au runtime, `isPro` lit le cache, **zéro réseau** (invariant
/// respecté, même catégorie que le download de modèle).
@MainActor
@Observable
final class LicenseStore {
    /// Clé activée et en cache, nil si non activée.
    private(set) var activatedKey: String?

    @ObservationIgnored private let activator: LicenseActivating

    init(activator: LicenseActivating = SignedLicenseActivator()) {
        self.activator = activator
        self.activatedKey = Self.loadVerifiedCachedKey()
    }

    /// Charge la clé en cache ET **re-vérifie sa signature** contre la clé publique
    /// embarquée. Une clé qui ne valide plus (paire tournée → révocation, ou cache
    /// trafiqué) est jetée → retour au tier gratuit. Sans ça, la signature ne serait
    /// contrôlée qu'à l'activation et le cache accepterait n'importe quelle chaîne
    /// (vérification « théâtre »). Lié au modèle B (offline signé) ; un modèle en
    /// ligne (LS) revaliderait autrement.
    nonisolated static func loadVerifiedCachedKey() -> String? {
        guard let cached = loadCachedKey() else { return nil }
        if LicenseKey.verify(cached, publicKeyBase64: LicenseGate.publicKeyBase64) != nil {
            return cached
        }
        clearCache()   // périmée / invalide → on nettoie
        return nil
    }

    /// **Studio débloqué ?** Kill switch off → toujours vrai (tout inclus). Sinon,
    /// vrai seulement si une licence est activée et en cache. C'est LE point de
    /// gating unique : chaque feature Studio appelle `isPro`.
    var isPro: Bool {
        Self.isProValue(paywallEnabled: LicenseGate.paywallEnabled, hasLicense: activatedKey != nil)
    }

    /// Vérité du gating, pure et testable (le drapeau réel est une constante
    /// compile-time, intestable directement) : paywall off → toujours débloqué ;
    /// paywall on → débloqué seulement avec une licence.
    nonisolated static func isProValue(paywallEnabled: Bool, hasLicense: Bool) -> Bool {
        !paywallEnabled || hasLicense
    }

    /// Vrai si une licence est effectivement activée (indépendant du kill switch) —
    /// pour l'UI de la section Licence.
    var isActivated: Bool { activatedKey != nil }

    /// Active une clé : appel réseau UNIQUE via l'activateur, puis cache Keychain.
    @discardableResult
    func activate(key: String) async -> Result<Void, LicenseError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        do {
            try await activator.activate(key: trimmed)
            Self.cacheKey(trimmed)
            activatedKey = trimmed
            Log.info(.ui, "license_activated")
            return .success(())
        } catch let e as LicenseError {
            Log.warn(.ui, "license_activation_failed")
            return .failure(e)
        } catch {
            Log.warn(.ui, "license_activation_failed")
            return .failure(.network)
        }
    }

    /// Retire la licence du cache (changement de Mac, test). N'appelle pas le
    /// réseau — la désactivation serveur (libérer un siège) se fera côté portail.
    func deactivate() {
        Self.clearCache()
        activatedKey = nil
        Log.info(.ui, "license_deactivated")
    }

    // MARK: - Cache Keychain (device-only, ne se synchronise pas via iCloud)

    nonisolated private static let service = "app.cocotypist.Souffleuse.license"
    nonisolated private static let account = "studio.licenseKey"

    nonisolated static func loadCachedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) { SecItemCopyMatching(query as CFDictionary, $0) }
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    nonisolated static func cacheKey(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.warn(.ui, "license_cache_write_failed") }
    }

    nonisolated static func clearCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
