# Déploiement Vercel — appcast Sparkle de Souffleuse

Ce dossier sert le flux de mises à jour que l'app interroge **sur clic** de
« Vérifier les mises à jour… » (`SUFeedURL = https://souffleuse.app/appcast.xml`,
mode manuel-only — aucun poll passif).

## Contenu

| Fichier | Rôle |
|---|---|
| `appcast.xml` | Le flux Sparkle. Une `<item>` par release. **Source de vérité, versionnée.** |
| `vercel.json` | En-têtes : `application/xml` pour l'appcast, `octet-stream` + cache long pour les `.dmg`. |
| `.gitignore` | Empêche de committer les `.dmg`/`downloads/` (les binaires vont sur Vercel, pas dans git). |

Le DMG est servi depuis `/downloads/Souffleuse-<version>.dmg` (uploadé sur Vercel,
**jamais** committé ici).

## Deux façons de brancher ça sur souffleuse.app

**Option A — fusionner dans ton site existant.**
Copie `appcast.xml` à la racine servie publiquement de ton projet (ex. `public/`
pour Next.js/Vite, ou la racine pour un site statique) et fusionne le bloc
`headers` de `vercel.json` dans le `vercel.json` du site. Place les `.dmg` sous
`public/downloads/` (ou uploade-les via le dashboard / un bucket).

**Option B — projet Vercel dédié.**
Déploie ce dossier tel quel comme projet statique Vercel, puis mappe le domaine
`souffleuse.app` (ou un sous-chemin) dessus.

> Vérifie après déploiement :
> `curl -sI https://souffleuse.app/appcast.xml | grep -i content-type`
> doit renvoyer `application/xml`.

## Publier une nouvelle release (checklist)

1. **Builder le DMG** (Developer ID, non notarisé — canal beta) :
   ```bash
   cd Souffleuse && RELEASE=1 NOTARIZE=0 ./make-app.sh
   # → build/Souffleuse.dmg
   ```
2. **Renommer** avec la version (doit matcher `CFBundleShortVersionString`) :
   ```bash
   cp build/Souffleuse.dmg build/Souffleuse-0.4.0.dmg
   ```
3. **Générer le bloc `<item>` signé** (signature EdDSA via le trousseau) :
   ```bash
   ../deploy/make-appcast-entry.sh build/Souffleuse-0.4.0.dmg
   ```
   Colle la sortie dans `appcast.xml` (en première `<item>` du `<channel>`).
4. **Uploader le `.dmg`** sur Vercel sous `/downloads/Souffleuse-0.4.0.dmg`.
5. **Déployer** l'`appcast.xml` mis à jour.
6. **Tester** : dans l'app, menu → « Vérifier les mises à jour… ».

## Rappels

- **HTTPS obligatoire** : Sparkle/ATS refusent un `SUFeedURL` en `http://`.
- **Non notarisé** = avertissement Gatekeeper au **1er** téléchargement
  (clic-droit → Ouvrir). Les MAJ suivantes installées par Sparkle passent mieux.
- **Clé privée EdDSA** : dans le trousseau du dev (+ backup hors repo). Si tu la
  perds, les installs existantes refuseront toute future MAJ.
- **Manuel-only** : ne jamais réintroduire `SUScheduledCheckInterval` ni
  `SUEnableAutomaticChecks=true` (invariant zero-leak, ARCHITECTURE.md §Pilier 3).
