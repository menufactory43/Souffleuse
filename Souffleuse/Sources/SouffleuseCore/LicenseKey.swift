import Foundation
import CryptoKit

/// Format + cryptographie des licences « Studio » **auto-signées** (Ed25519).
/// La clé est AUTONOME : elle porte l'email de l'acheteur + la signature, donc
/// l'app la vérifie **hors ligne** avec la clé publique embarquée — aucun réseau,
/// jamais (même à l'activation). Le générateur (dev, clé PRIVÉE) signe ; l'app
/// (clé PUBLIQUE) vérifie. Forme : « SOUF-<b64url(email)>.<b64url(signature)> ».
public enum LicenseKey {
    public static let prefix = "SOUF-"

    /// Email normalisé (minuscules + trim) — la base canonique signée/vérifiée.
    static func canonical(_ email: String) -> String {
        email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Octets signés pour un email.
    public static func payload(email: String) -> Data {
        Data(canonical(email).utf8)
    }

    /// Assemble une clé lisible depuis un email et sa signature.
    public static func encode(email: String, signature: Data) -> String {
        prefix + base64url(Data(canonical(email).utf8)) + "." + base64url(signature)
    }

    /// Décompose une clé en (email, signature) ; nil si la forme est invalide.
    public static func decode(_ key: String) -> (email: String, signature: Data)? {
        guard key.hasPrefix(prefix) else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let emailData = base64urlDecode(String(parts[0])),
              let email = String(data: emailData, encoding: .utf8),
              let sig = base64urlDecode(String(parts[1])) else { return nil }
        return (email, sig)
    }

    /// Vérifie une clé avec la clé publique (base64 raw). Renvoie l'email si la
    /// signature est valide, nil sinon. **Hors ligne, pur.**
    public static func verify(_ key: String, publicKeyBase64: String) -> String? {
        guard let (email, sig) = decode(key),
              let pubData = Data(base64Encoded: publicKeyBase64),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
              pub.isValidSignature(sig, for: payload(email: email)) else { return nil }
        return email
    }

    /// Signe (DEV, clé privée base64 raw) → clé licence. Utilisé par le générateur.
    public static func sign(email: String, privateKeyBase64: String) -> String? {
        guard let privData = Data(base64Encoded: privateKeyBase64),
              let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData),
              let sig = try? priv.signature(for: payload(email: email)) else { return nil }
        return encode(email: email, signature: sig)
    }

    // MARK: - base64url (sans padding)

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
