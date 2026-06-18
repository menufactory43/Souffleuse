import Foundation
import Observation
import Security
import SouffleuseCore
import SouffleuseLog

/// **Kill switch GLOBAL du paywall.** `false` (défaut) → `isPro` est TOUJOURS
/// vrai : tout Souffleuse Studio est déverrouillé, le gating dort, rien ne change
/// pour personne. Passe-le à `true` pour activer le mur (licence requise) ;
/// repasse-le à `false` pour **revert instantanément**. Constante compile-time :
/// un flip = un rebuild, aucune migration, aucune donnée touchée.
enum LicenseGate {
    static let paywallEnabled = false

    /// Page de **choix du moyen de paiement** (carte via Lemon Squeezy, ou Bitcoin
    /// via Lightning). Hébergée par le service de licences (`/buy/studio`), localisée
    /// FR/EN. Le bouton « Acheter » des Préférences l'ouvre ; la cible Lemon Squeezy
    /// directe vit désormais côté serveur (`LEMON_URL` dans `licensed.py`).
    static let purchaseURL = URL(string: "https://pay.souffleuse.app/buy/studio")!

    /// Clé PUBLIQUE Ed25519 (base64) — utilisée UNIQUEMENT par la voie offline
    /// signée (`SignedLicenseActivator`), conservée en fallback. Inutilisée tant
    /// qu'on est sur l'activation Lemon Squeezy.
    static let publicKeyBase64 = "XIFWI8qTZ1bjLdWVlPK1F5IDlPWhfIpiI+uhVQkhIec="
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

/// Frontière d'activation. `activate` valide la clé (réseau pour LS, signature
/// pour l'offline) et renvoie un identifiant d'instance opaque à conserver pour
/// la désactivation (nil si le modèle n'en a pas). `deactivate` libère le siège
/// côté serveur (no-op pour l'offline). Isolée derrière un protocole → testable.
protocol LicenseActivating: Sendable {
    func activate(key: String) async throws -> String?
    func deactivate(key: String, instanceId: String?) async throws
}

/// Activateur **Lemon Squeezy** : POST `/v1/licenses/activate` (sans clé secrète —
/// endpoint client). UN appel réseau à l'activation, puis cache local → runtime
/// offline. Récupère LS aussi : limite d'appareils + révocation + visibilité.
struct LemonSqueezyActivator: LicenseActivating {
    private static let base = "https://api.lemonsqueezy.com/v1/licenses/"

    func activate(key: String) async throws -> String? {
        let json = try await post("activate", [
            "license_key": key,
            "instance_name": Self.deviceName,
        ])
        guard (json["activated"] as? Bool) == true else {
            throw Self.mapError(json["error"] as? String)
        }
        // instance.id (UUID string) à conserver pour libérer le siège plus tard.
        return (json["instance"] as? [String: Any])?["id"] as? String
    }

    func deactivate(key: String, instanceId: String?) async throws {
        guard let instanceId else { return }
        _ = try? await post("deactivate", ["license_key": key, "instance_id": instanceId])
    }

    private func post(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: Self.base + path) else { throw LicenseError.network }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(Self.encode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseError.network
        }
        return json
    }

    nonisolated static var deviceName: String { Host.current().localizedName ?? "Mac" }

    private static let allowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-_.~")
        return s
    }()
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func mapError(_ error: String?) -> LicenseError {
        let e = (error ?? "").lowercased()
        if e.contains("limit") || e.contains("activation usage") { return .deviceLimitReached }
        return .invalidKey
    }
}

/// Stub de dev (placeholder) : accepte une clé non vide préfixée « SOUF- », sans
/// réseau. Conservé pour les TESTS.
struct StubLicenseActivator: LicenseActivating {
    func activate(key: String) async throws -> String? {
        guard key.hasPrefix("SOUF-"), key.count >= 10 else { throw LicenseError.invalidKey }
        return nil
    }
    func deactivate(key: String, instanceId: String?) async throws {}
}

/// Activateur OFFLINE signé (Ed25519, `LicenseKey`) — fallback conservé si on
/// repasse au modèle hors-ligne. Vérifie la signature avec la clé publique
/// embarquée, zéro réseau.
struct SignedLicenseActivator: LicenseActivating {
    /// Clé publique de vérif. Défaut = celle embarquée ; injectable pour les tests
    /// (signer avec une paire de test sans dépendre de la clé de prod).
    let publicKeyBase64: String

    init(publicKeyBase64: String = LicenseGate.publicKeyBase64) {
        self.publicKeyBase64 = publicKeyBase64
    }

    func activate(key: String) async throws -> String? {
        guard LicenseKey.verify(key, publicKeyBase64: publicKeyBase64) != nil else {
            throw LicenseError.invalidKey
        }
        return nil
    }
    func deactivate(key: String, instanceId: String?) async throws {}
}

/// Activateur COMPOSITE : un SEUL champ d'activation accepte les DEUX rails de
/// vente, sans que l'app sache « comment » l'utilisateur a payé.
///
/// - Un **jeton auto-signé** (`SOUF-…`, émis après paiement par n'importe quel
///   canal — Bitcoin/BTCPay, virement, etc.) → vérifié **hors ligne** par la
///   signature (zéro réseau, fidèle à l'invariant).
/// - Sinon, la clé est traitée comme une **clé Lemon Squeezy** → activation en
///   ligne (limite d'appareils, révocation).
///
/// Le tri se fait par la FORME du jeton (signature valide pour la clé publique
/// embarquée), pas par essai/erreur réseau. `publicKeyBase64` est injectable pour
/// la testabilité du routage.
struct CompositeLicenseActivator: LicenseActivating {
    let offline: LicenseActivating
    let online: LicenseActivating
    let publicKeyBase64: String

    init(
        offline: LicenseActivating = SignedLicenseActivator(),
        online: LicenseActivating = LemonSqueezyActivator(),
        publicKeyBase64: String = LicenseGate.publicKeyBase64
    ) {
        self.offline = offline
        self.online = online
        self.publicKeyBase64 = publicKeyBase64
    }

    /// Jeton auto-signé valide pour notre clé publique ? → voie hors ligne.
    private func isSignedToken(_ key: String) -> Bool {
        LicenseKey.verify(key, publicKeyBase64: publicKeyBase64) != nil
    }

    func activate(key: String) async throws -> String? {
        try await (isSignedToken(key) ? offline : online).activate(key: key)
    }

    func deactivate(key: String, instanceId: String?) async throws {
        try await (isSignedToken(key) ? offline : online).deactivate(key: key, instanceId: instanceId)
    }
}

/// Enregistrement de licence en cache (clé + instance LS pour la désactivation).
private struct CachedLicense: Codable {
    let key: String
    let instanceId: String?
}

/// Licence « Studio » (achat unique). Activation déléguée à `LicenseActivating`
/// (Lemon Squeezy par défaut : UN appel réseau), résultat mis en cache LOCALEMENT
/// (Keychain device-only) → au runtime, `isPro` lit le cache, **zéro réseau**.
@MainActor
@Observable
final class LicenseStore {
    /// Clé activée et en cache, nil si non activée.
    private(set) var activatedKey: String?
    /// Instance LS associée (siège), pour la désactivation.
    @ObservationIgnored private var instanceId: String?

    @ObservationIgnored private let activator: LicenseActivating

    init(activator: LicenseActivating = CompositeLicenseActivator()) {
        self.activator = activator
        if let cached = Self.loadCached() {
            self.activatedKey = cached.key
            self.instanceId = cached.instanceId
        }
    }

    /// **Studio débloqué ?** Kill switch off → toujours vrai. Sinon, vrai si une
    /// licence est activée et en cache.
    var isPro: Bool {
        Self.isProValue(paywallEnabled: LicenseGate.paywallEnabled, hasLicense: activatedKey != nil)
    }

    /// Vrai si une licence est activée (indépendant du kill switch), pour l'UI.
    var isActivated: Bool { activatedKey != nil }

    /// Vérité du gating, pure et testable : paywall off → toujours débloqué ;
    /// paywall on → débloqué seulement avec une licence.
    nonisolated static func isProValue(paywallEnabled: Bool, hasLicense: Bool) -> Bool {
        !paywallEnabled || hasLicense
    }

    /// Active une clé : délègue à l'activateur (réseau pour LS), puis cache.
    @discardableResult
    func activate(key: String) async -> Result<Void, LicenseError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        do {
            let instance = try await activator.activate(key: trimmed)
            Self.cache(CachedLicense(key: trimmed, instanceId: instance))
            activatedKey = trimmed
            instanceId = instance
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

    /// Désactive sur ce Mac : retire le cache TOUT DE SUITE (local) et libère le
    /// siège LS en arrière-plan (best-effort — n'échoue pas si hors ligne).
    func deactivate() {
        let key = activatedKey
        let inst = instanceId
        Self.clearCache()
        activatedKey = nil
        instanceId = nil
        Log.info(.ui, "license_deactivated")
        if let key {
            let act = activator
            Task { try? await act.deactivate(key: key, instanceId: inst) }
        }
    }

    // MARK: - Cache Keychain (device-only, ne se synchronise pas via iCloud)

    nonisolated private static let service = "app.cocotypist.Souffleuse.license"
    nonisolated private static let account = "studio.license"

    nonisolated private static func loadCached() -> CachedLicense? {
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
              let cached = try? JSONDecoder().decode(CachedLicense.self, from: data),
              !cached.key.isEmpty else { return nil }
        return cached
    }

    nonisolated private static func cache(_ license: CachedLicense) {
        guard let data = try? JSONEncoder().encode(license) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            Log.warn(.ui, "license_cache_write_failed")
        }
    }

    nonisolated private static func clearCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
