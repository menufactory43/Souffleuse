#!/usr/bin/env bash
# Génère un bloc <item> d'appcast Sparkle SIGNÉ pour un DMG donné.
#
# Usage :
#   deploy/make-appcast-entry.sh <chemin/vers/Souffleuse.dmg> [version]
#
# - Lit la version depuis l'argument, sinon depuis le CFBundleShortVersionString
#   de Souffleuse/Resources/Info.plist.
# - Appelle `sign_update` (clé privée EdDSA lue automatiquement dans le trousseau)
#   pour obtenir sparkle:edSignature + length.
# - Imprime un bloc <item> prêt à coller dans deploy/vercel/appcast.xml.
#
# Le DMG produit par `RELEASE=1 NOTARIZE=0 Souffleuse/make-app.sh` est
# build/Souffleuse.dmg ; copie-le dans website/dl/Souffleuse.dmg (fichier unique,
# servi via /dl/, écrasé à chaque release) puis lance ce script dessus.
#
# NB : l'enclosure de l'appcast pointe toujours sur https://souffleuse.app/Souffleuse.dmg
# (URL inchangée) ; ce chemin est réécrit côté Vercel vers l'Edge Function
# /api/download qui compte le téléchargement puis redirige (302) vers /dl/Souffleuse.dmg.
# La signature EdDSA porte sur les octets du DMG, donc le redirect est transparent.
set -euo pipefail

DMG="${1:?usage: make-appcast-entry.sh <chemin.dmg> [version]}"
[ -f "$DMG" ] || { echo "DMG introuvable : $DMG" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$REPO_ROOT/Souffleuse/Resources/Info.plist"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"

# sign_update est un binaire éphémère résolu par SPM ; on le retrouve dynamiquement.
SIGN_UPDATE="$(find "$REPO_ROOT/Souffleuse/.build" "$REPO_ROOT/Souffleuse/build" \
  -name sign_update -type f 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
  echo "sign_update introuvable. Lance d'abord :  (cd Souffleuse && swift package resolve)" >&2
  exit 1
fi

# sign_update imprime :  sparkle:edSignature="..." length="..."
SIG_ATTRS="$("$SIGN_UPDATE" "$DMG")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Convention du site : un seul Souffleuse.dmg à la racine, écrasé à chaque release.
cat <<EOF

<!-- ─── <item> version ${VERSION} — remplace l'<item> existante dans website/appcast.xml ─── -->
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>Souffleuse ${VERSION}</h2>
        <ul>
          <li>TODO : notes de version.</li>
        </ul>
      ]]></description>
      <enclosure
        url="https://souffleuse.app/Souffleuse.dmg"
        ${SIG_ATTRS}
        type="application/octet-stream" />
    </item>
EOF
