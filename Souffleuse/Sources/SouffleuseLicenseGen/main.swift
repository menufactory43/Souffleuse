import CryptoKit
import Foundation
import SouffleuseCore

// Outil DEV : génère une paire de clés Ed25519 et signe des licences « Studio ».
// (Exécutable hors app — hors `SHIPPING_DIRS`, donc `print` autorisé.)
//
//   swift run SouffleuseLicenseGen genkeys
//   swift run SouffleuseLicenseGen sign --private <b64> --email gabriel@exemple.fr
//   swift run SouffleuseLicenseGen verify --key SOUF-… --public <b64>
//
// La clé PRIVÉE reste secrète chez toi (sert à signer ce que tu vends). La clé
// PUBLIQUE s'embarque dans l'app (`LicenseGate.publicKeyBase64`) pour vérifier.

func b64(_ d: Data) -> String { d.base64EncodedString() }

let args = CommandLine.arguments

func fail(_ msg: String) -> Never {
    print(msg)
    exit(1)
}

guard args.count >= 2 else {
    fail("Usage:\n  SouffleuseLicenseGen genkeys\n  SouffleuseLicenseGen sign --private <b64> --email <email>\n  SouffleuseLicenseGen verify --key <SOUF-…> --public <b64>")
}

switch args[1] {
case "genkeys":
    let priv = Curve25519.Signing.PrivateKey()
    print("PRIVATE (garde SECRET, ne commit jamais) :")
    print("  \(b64(priv.rawRepresentation))")
    print("PUBLIC  (à coller dans LicenseGate.publicKeyBase64) :")
    print("  \(b64(priv.publicKey.rawRepresentation))")

case "sign":
    var privateB64: String?
    var email: String?
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--private": i += 1; privateB64 = i < args.count ? args[i] : nil
        case "--email":   i += 1; email = i < args.count ? args[i] : nil
        default: break
        }
        i += 1
    }
    guard let pk = privateB64, let mail = email else {
        fail("Erreur : --private <b64> et --email <email> sont requis.")
    }
    guard let key = LicenseKey.sign(email: mail, privateKeyBase64: pk) else {
        fail("Erreur : clé privée invalide.")
    }
    print(key)

case "verify":
    // Preuve bout-en-bout du flux Bitcoin : vérifier HORS LIGNE qu'un jeton
    // (émis après paiement, signé par la clé privée) est valide pour la clé
    // publique embarquée — exactement ce que fait l'app à l'activation.
    var keyArg: String?
    var publicB64: String?
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--key":    i += 1; keyArg = i < args.count ? args[i] : nil
        case "--public": i += 1; publicB64 = i < args.count ? args[i] : nil
        default: break
        }
        i += 1
    }
    guard let k = keyArg, let pub = publicB64 else {
        fail("Erreur : --key <SOUF-…> et --public <b64> sont requis.")
    }
    if let email = LicenseKey.verify(k, publicKeyBase64: pub) {
        print("VALID — licence signée pour : \(email)")
    } else {
        fail("INVALID — signature non valide pour cette clé publique.")
    }

default:
    fail("Commande inconnue : \(args[1])")
}
