#!/bin/bash
# Crea "Easy F24.app" per macOS 11 Big Sur o successivo, Intel e Apple Silicon.
#
#   ./scripts/build.sh                  → build/Easy F24.app, build/Easy_F24.dmg e build/Easy_F24.zip
#   ARCHS=x86_64 ./scripts/build.sh     → solo Intel
#
# Basta avere gli Strumenti da riga di comando (xcode-select --install), Xcode non serve.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Easy F24"
EXECUTABLE="EasyF24"
MIN_MACOS="11.0"
ARCHS="${ARCHS:-x86_64 arm64}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/Easy_F24.dmg"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP" "$DMG" "$BUILD_DIR/Easy_F24.zip" "$BUILD_DIR/SHA256SUMS.txt"
mkdir -p "$BUILD_DIR"

binaries=()
for arch in $ARCHS; do
    echo "→ Compilo per $arch (macOS $MIN_MACOS o successivo)…"
    mkdir -p "$BUILD_DIR/$arch"
    xcrun swiftc \
        -O -whole-module-optimization \
        -swift-version 5 \
        -parse-as-library \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MIN_MACOS" \
        -module-name "$EXECUTABLE" \
        -o "$BUILD_DIR/$arch/$EXECUTABLE" \
        Sources/EasyF24/*.swift
    binaries+=("$BUILD_DIR/$arch/$EXECUTABLE")
done

echo "→ Creo $APP_NAME.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/container-migration.plist "$APP/Contents/Resources/container-migration.plist"
# La licenza Apache 2.0 chiede di distribuire licenza e NOTICE insieme all'app.
cp LICENSE NOTICE "$APP/Contents/Resources/"
# Firma ad-hoc con sandbox (Resources/EasyF24.entitlements) e runtime protetto,
# che impedisce di iniettare codice nell'app.
codesign --force --sign - --options runtime --entitlements Resources/EasyF24.entitlements "$APP"

(cd "$BUILD_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "Easy_F24.zip")

echo "→ Creo Easy_F24.dmg…"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applicazioni"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGING"

# Impronte SHA-256, da pubblicare con la release per controllare che i file scaricati siano integri.
(cd "$BUILD_DIR" && shasum -a 256 Easy_F24.dmg Easy_F24.zip > SHA256SUMS.txt)

echo "✓ Fatto: $APP e $DMG"
echo "  Per installarla apri il .dmg e trascina l'app su Applicazioni."
