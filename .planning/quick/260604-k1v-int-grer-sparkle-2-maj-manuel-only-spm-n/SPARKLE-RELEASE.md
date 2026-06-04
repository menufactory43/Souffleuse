# Souffleuse — Sparkle 2 Release Guide

Guide dev pour générer les clés EdDSA, signer une release, et publier un appcast.
Toutes les commandes impliquant le trousseau macOS sont des étapes manuelles.

---

## 1. Génération des clés EdDSA (étape MANUELLE, une seule fois)

Sparkle 2 signe les releases avec Ed25519. La clé privée vit dans le trousseau de
session macOS (jamais exportée, jamais committée). Seule la clé publique va dans
`Info.plist`.

### Trouver le binaire `generate_keys`

Après un `swift package resolve` ou un build, cherche le binaire dans le checkout SPM :

```bash
find Souffleuse/build -name generate_keys
# Chemin typique :
# Souffleuse/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

### Générer la paire de clés

```bash
# Depuis le répertoire Souffleuse/
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

- La clé **privée** est stockée automatiquement dans le trousseau de la session macOS.
- La clé **publique** base64 est affichée dans le terminal. Exemple :
  ```
  Public signing key (SUPublicEDKey in Info.plist):
  AXivPBlEGcl+pFExWj/IWDcxqUFuXhbkRMtWJMlPBiA=
  ```

### Mettre à jour Info.plist

Copier la valeur affichée dans `Souffleuse/Resources/Info.plist` :

```xml
<key>SUPublicEDKey</key>
<string>AXivPBlEGcl+pFExWj/IWDcxqUFuXhbkRMtWJMlPBiA=</string>
```

Remplacer `PLACEHOLDER_REMPLACER_PAR_LA_CLE_PUBLIQUE_EDDSA` par la valeur réelle.

> **NE JAMAIS** committer la clé privée. Elle ne quitte jamais le trousseau.
> Ne pas exporter `~/Library/Keychains/` dans le repo.

---

## 2. Signer une release

### Build Developer ID (non notarisé, beta)

```bash
cd Souffleuse
RELEASE=1 NOTARIZE=0 ./make-app.sh
# Produit : build/Souffleuse.dmg (signé Developer ID, non staplé)
```

### Trouver le binaire `sign_update`

```bash
find Souffleuse/build -name sign_update
# Chemin typique :
# Souffleuse/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
```

### Signer le DMG

```bash
./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update build/Souffleuse.dmg
```

Sortie exemple :

```
sparkle:edSignature="Fp3YkXMVwKBmVtPL8Q8vBjKDPJJcQjFf4RSmAbCXIK4X5H0jQ8..."  length="12345678"
```

Ces deux valeurs (`sparkle:edSignature` et `length`) sont à coller dans l'item
`<enclosure>` de l'appcast.xml (voir section 3).

---

## 3. Template appcast.xml

L'appcast vit sur le **repo du site Vercel** (pas dans ce repo). Exemple de structure :

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Souffleuse</title>
    <link>https://souffleuse.app/appcast.xml</link>
    <description>Canal de mise à jour Souffleuse</description>
    <language>fr</language>
    <item>
      <title>Souffleuse 0.4.1</title>
      <sparkle:version>0.4.1</sparkle:version>
      <sparkle:shortVersionString>0.4.1</sparkle:shortVersionString>
      <pubDate>Thu, 05 Jun 2026 12:00:00 +0000</pubDate>
      <sparkle:releaseNotesLink>https://souffleuse.app/release-notes/0.4.1.html</sparkle:releaseNotesLink>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://souffleuse.app/releases/Souffleuse-0.4.1.dmg"
        sparkle:edSignature="REMPLACER_PAR_SIGNATURE_sign_update"
        length="REMPLACER_PAR_LENGTH_sign_update"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

Notes :
- `<sparkle:version>` = `CFBundleVersion` (ex. `0.4.1`).
- `<sparkle:shortVersionString>` = `CFBundleShortVersionString` (même valeur ici).
- `<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>` = macOS 14 minimum.
- `url` en **HTTPS** obligatoire (ATS + Sparkle refusent http://).
- `sparkle:edSignature` et `length` fournis par `sign_update` (voir section 2).

---

## 4. Rappels — Contraintes verrouillées

| Contrainte | Valeur | Raison |
|---|---|---|
| `SUEnableAutomaticChecks` | `false` | Zero-leak (ARCHITECTURE.md:339) |
| `SUScheduledCheckInterval` | **absent** | Aucun poll passif — ne pas réintroduire |
| Mode | Manuel-only | L'utilisateur clique « Vérifier les mises à jour… » |
| Distribution beta | Developer ID, NON notarisé | Friction Gatekeeper acceptée à la 1re ouverture |
| Feed URL | `https://` | HTTPS obligatoire (ATS + Sparkle) |
| Clé privée | Trousseau macOS uniquement | Jamais dans le repo, jamais exportée |

**A la 1re ouverture d'une version non notarisée sur une autre machine :**
clic-droit → Ouvrir, ou Réglages Système → Confidentialité → « Ouvrir quand même ».

---

## 5. Follow-ups hors-scope (non bloquants)

Ces étapes sont volontairement hors du scope de cette intégration :

- **Déployer appcast.xml + DMG** sur le site Vercel (repo site séparé).
- **Exécuter `generate_keys`** : étape manuelle touchant le trousseau — ne peut pas être automatisée.
- **Exécuter `sign_update`** : idem, nécessite la clé privée dans le trousseau.
- **Notarisation future** : passer `NOTARIZE=1` dans `make-app.sh` + configurer `xcrun notarytool store-credentials`. Voir commentaire dans `make-app.sh` (section RELEASE).
- **Auto-update futur** : passage à `SUEnableAutomaticChecks=true` + `SUScheduledCheckInterval` — refusé en v1 par ARCHITECTURE.md:339. Décision à réviser explicitement.
