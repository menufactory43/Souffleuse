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

## 3. Appcast — emplacement réel et publication

Le site Vercel est **dans ce repo** : `website/` (site statique, servi depuis la
racine, lié à Vercel via `website/.vercel`). Les fichiers canoniques sont versionnés :

| Fichier | Rôle |
|---|---|
| `website/appcast.xml` | Le flux Sparkle (source de vérité, versionnée). |
| `website/vercel.json` | En-têtes : `application/xml` pour l'appcast, `octet-stream` pour le DMG. |
| `website/Souffleuse.dmg` | Le binaire **unique** servi à la racine, écrasé à chaque release (gitignoré). |

**Convention fichier unique** : un seul `Souffleuse.dmg` à
`https://souffleuse.app/Souffleuse.dmg`, écrasé à chaque version. On garde donc
**une seule `<item>`** dans l'appcast (l'URL est réutilisée) ; `edSignature` +
`length` doivent être régénérés en même temps que le DMG uploadé. Cache court +
`must-revalidate` sur le DMG (cf. `vercel.json`) pour éviter de servir un cache périmé.

### Boucle de release

```bash
# 1. Builder le DMG AVEC Sparkle (Developer ID, non notarisé)
cd Souffleuse && RELEASE=1 NOTARIZE=0 ./make-app.sh        # → build/Souffleuse.dmg

# 2. Le placer à la racine du site (fichier unique servi en statique)
cp build/Souffleuse.dmg ../website/Souffleuse.dmg

# 3. Générer l'<item> signé et la coller dans website/appcast.xml
../deploy/make-appcast-entry.sh ../website/Souffleuse.dmg

# 4. Déployer (depuis website/, où vit le lien .vercel)
cd ../website && vercel deploy --prod
```

Vérif post-déploiement :
`curl -sI https://souffleuse.app/appcast.xml | grep -i content-type` → `application/xml`.

Notes :
- `<sparkle:version>` = `CFBundleVersion`, `<sparkle:shortVersionString>` = `CFBundleShortVersionString` (0.4.0).
- `url` en **HTTPS** obligatoire (ATS + Sparkle refusent http://).
- `sparkle:edSignature` + `length` fournis par `sign_update` via le script (section 2).

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

- **Déployer appcast.xml + DMG** sur Vercel (`website/`, dans ce repo) — cf. section 3.
- **Exécuter `generate_keys`** : ✅ fait le 2026-06-04, clé publique dans `Info.plist`, privée au trousseau (+ backup hors repo).
- **Exécuter `sign_update`** : idem, nécessite la clé privée dans le trousseau.
- **Notarisation future** : passer `NOTARIZE=1` dans `make-app.sh` + configurer `xcrun notarytool store-credentials`. Voir commentaire dans `make-app.sh` (section RELEASE).
- **Auto-update futur** : passage à `SUEnableAutomaticChecks=true` + `SUScheduledCheckInterval` — refusé en v1 par ARCHITECTURE.md:339. Décision à réviser explicitement.
