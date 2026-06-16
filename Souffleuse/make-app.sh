#!/usr/bin/env bash
# Build Souffleuse.app from the xcodebuild output + Resources/Info.plist.
# Use this until we have a proper Xcode project or swift-bundler integration.
set -euo pipefail

cd "$(dirname "$0")"

# Release mode (RELEASE=1) : signature Developer ID + timestamp sécurisé +
# entitlements MLX, puis notarisation + staple + fabrication du .dmg pour le site.
# Par défaut on garde le flux dev rapide : cert Apple Development, pas de
# timestamp/réseau, pas de DMG (build local + TCC stable).
RELEASE="${RELEASE:-}"
if [ -n "$RELEASE" ]; then
  CONFIGURATION="${CONFIGURATION:-Release}"
  DEFAULT_SIGN="AE1E2158E210E923EF75A6214C188D5D7A56F71B"   # Developer ID Application: Gabriel Turpin (AKMNXGVVGX)
  TIMESTAMP_FLAG="--timestamp"
  ENTITLEMENTS_ARG="--entitlements Resources/Souffleuse.entitlements"
else
  CONFIGURATION="${CONFIGURATION:-Debug}"
  DEFAULT_SIGN="A798891AB1B0A8C0B46AFADBD95094BABF680037"   # Apple Development (TCC-stable en dev)
  TIMESTAMP_FLAG="--timestamp=none"
  ENTITLEMENTS_ARG=""
fi
BUILD_DIR="build/Build/Products/$CONFIGURATION"
APP_NAME="Souffleuse"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> xcodebuild ($CONFIGURATION)..."
# XCB_EXTRA : build-settings optionnels passés tels quels à xcodebuild (ex.
# « SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule » pour un
# build Debug avec perf release — flag DEBUG/assertions conservés, vitesse -O).
xcodebuild -scheme "$APP_NAME" -derivedDataPath ./build -destination "platform=macOS" -configuration "$CONFIGURATION" build \
  -quiet \
  ${XCB_EXTRA:-} \
  | tail -5

if [ ! -x "$BUILD_DIR/$APP_NAME" ]; then
  echo "Binary not found at $BUILD_DIR/$APP_NAME"
  exit 1
fi

echo "==> Building .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the vendored llama.cpp dylibs so the @rpath/@loader_path lookups in the
# signed binary resolve at runtime (mirror of how MLX ships its Cmlx bundle).
# The dylibs carry @rpath install names and the app binary links with rpaths
# pointing at @executable_path/../Frameworks and @loader_path/../Frameworks.
LLAMA_LIB_DIR="vendor/llama/lib"
for dylib in libllama.0.dylib libggml.0.dylib libggml-base.0.dylib \
             libggml-cpu.0.dylib libggml-metal.0.dylib libggml-blas.0.dylib; do
  cp "$LLAMA_LIB_DIR/$dylib" "$APP_BUNDLE/Contents/Frameworks/$dylib"
done

# Copier Sparkle.framework (binary XCFramework résolu par SPM/xcodebuild).
# xcodebuild ne l'embarque pas automatiquement dans ce flux bundle-à-la-main ;
# on le localise + copie explicitement, comme les dylibs llama.
SPARKLE_FW=$(find build -name 'Sparkle.framework' -type d | head -1)
[ -n "$SPARKLE_FW" ] || { echo "Sparkle.framework introuvable — verifier la resolution SPM"; exit 1; }
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Copy the mlx-swift_Cmlx.bundle (metallib) so MLX can find its Metal kernels.
if [ -d "$BUILD_DIR/mlx-swift_Cmlx.bundle" ]; then
  cp -R "$BUILD_DIR/mlx-swift_Cmlx.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy any other resource bundles produced by SPM (per-target bundles).
for b in "$BUILD_DIR"/*.bundle; do
  [ -d "$b" ] || continue
  cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
done

# Make the executable, well, executable.
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Sign with a stable Apple Development cert rather than ad-hoc.
# Ad-hoc signing gives a fresh cdhash every rebuild, which makes TCC treat
# each build as a brand-new app and silently invalidate previously-granted
# Accessibility / Screen Recording permissions. A real cert produces a
# stable Designated Requirement and cdhash family, so TCC entries persist
# across rebuilds and the user only has to grant permissions once.
#
# SIGN_IDENTITY can be overridden via env var (e.g. switch back to "-" for
# ad-hoc on machines without the cert, or to point at a different identity).
SIGN_IDENTITY="${SIGN_IDENTITY:-$DEFAULT_SIGN}"

# Signer Sparkle.framework inside-out : les bundles XPC imbriqués DOIVENT être
# signés AVANT le framework outer (exigence de signature inside-out — sinon la
# signature outer invalide et codesign --verify --deep --strict échoue).
# Pas d'entitlements sur les composants Sparkle (comme les dylibs : entitlements
# uniquement sur l'exécutable principal).
SP="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SP" ]; then
  for nested in \
    "$SP/Versions/B/XPCServices/Downloader.xpc" \
    "$SP/Versions/B/XPCServices/Installer.xpc" \
    "$SP/Versions/B/Updater.app" \
    "$SP/Versions/B/Autoupdate"; do
    [ -e "$nested" ] || continue
    codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG "$nested"
  done
  codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG "$SP"
fi

# Sign nested dylibs first (inside-out signing requirement). Without this the
# outer bundle signature is invalid and dyld refuses to load the libraries.
# (Pas d'entitlements sur les dylibs — ils vont sur l'exécutable principal.)
for dylib in "$APP_BUNDLE/Contents/Frameworks"/*.dylib; do
  [ -f "$dylib" ] || continue
  codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG "$dylib"
done

codesign --force --sign "$SIGN_IDENTITY" --identifier app.cocotypist.Souffleuse \
  --options runtime $TIMESTAMP_FLAG $ENTITLEMENTS_ARG \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign "$SIGN_IDENTITY" --identifier app.cocotypist.Souffleuse \
  --options runtime $TIMESTAMP_FLAG $ENTITLEMENTS_ARG \
  "$APP_BUNDLE"

echo "==> Bundle: $APP_BUNDLE"
echo "==> Signed with: $SIGN_IDENTITY"

if [ -z "$RELEASE" ]; then
  echo "==> Launch via 'open' so launchd assigns the correct TCC identity:"
  echo "      open '$APP_BUNDLE'"
  echo "==> Permissions persist across rebuilds with the stable cert. If a"
  echo "    TCC prompt re-appears it means the cert was rotated — re-grant once."
  exit 0
fi

# ── RELEASE : (notarisation +) staple + DMG ─────────────────────────────────
# Pré-requis notarisation (une fois) : un profil notarytool dans le trousseau —
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --apple-id TON_EMAIL --team-id AKMNXGVVGX --password MOT-DE-PASSE-APP
#
# NOTARIZE=0 : saute la notarisation (et le staple, qui en dépend). L'app reste
# signée Developer ID avec timestamp + runtime durci → Gatekeeper la laisse
# s'ouvrir via « Ouvrir quand même » (clic-droit Ouvrir / Réglages → Confiance),
# sans aller-retour réseau chez Apple. Utile pour un partage rapide hors site.
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-souffleuse}"
DMG_PATH="build/$APP_NAME.dmg"
ZIP_PATH="build/$APP_NAME-notarize.zip"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Notarisation de l'app (peut prendre quelques minutes)..."
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP_PATH"

  echo "==> Staple du ticket sur l'app..."
  xcrun stapler staple "$APP_BUNDLE"
else
  echo "==> NOTARIZE=0 : notarisation sautée (app signée Developer ID, non staplée)."
fi

echo "==> Fabrication du DMG (avec lien /Applications pour le glisser-déposer)..."
STAGING="build/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
# Icône de volume (kit Resources/Brand). hdiutil -srcfolder ne propage PAS le
# bit custom-icon du dossier source (vérifié) : il faut la recette classique —
# DMG inscriptible, monter, poser le bit sur la RACINE DU VOLUME, convertir en
# UDZO compressé. SetFile vit dans les Command Line Tools ; absent, on retombe
# sur le create direct (DMG fonctionnel, icône de volume générique).
if [ -f "Resources/Brand/VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
  cp "Resources/Brand/VolumeIcon.icns" "$STAGING/.VolumeIcon.icns"
  RW_DMG="build/$APP_NAME-rw.dmg"
  rm -f "$RW_DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"
  MOUNT_POINT=$(hdiutil attach -nobrowse "$RW_DMG" | tail -1 | awk -F'\t' '{print $NF}')
  SetFile -a C "$MOUNT_POINT"
  hdiutil detach "$MOUNT_POINT"
  hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH" -ov
  rm -f "$RW_DMG"
else
  [ -f "Resources/Brand/VolumeIcon.icns" ] && echo "==> SetFile introuvable : DMG sans icône de volume."
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
fi
rm -rf "$STAGING"

echo "==> Signature du DMG..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Notarisation + staple du DMG..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo ""
  echo "==> ✅ Prêt pour le site : $DMG_PATH (notarisé + staplé, s'ouvre sans avertissement)"
  echo "==> Vérifie : spctl -a -vvv -t install '$DMG_PATH'  (doit dire 'accepted source=Notarized Developer ID')"
else
  echo ""
  echo "==> ✅ DMG signé Developer ID (non notarisé) : $DMG_PATH"
  echo "==> À la 1ʳᵉ ouverture sur une autre machine : clic-droit → Ouvrir, ou"
  echo "    Réglages Système → Confidentialité et sécurité → « Ouvrir quand même »."
fi
