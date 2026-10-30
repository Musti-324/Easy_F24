#!/bin/bash
# Crea "Easy F12.app" per macOS 11 Big Sur o successivo, Intel e Apple Silicon.
#
#   ./scripts/build.sh                  → build/Easy F12.app  e  build/Easy-F12.zip
#   ARCHS=x86_64 ./scripts/build.sh     → solo Intel
#
# Basta avere gli Strumenti da riga di comando (xcode-select --install), Xcode non serve.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Easy F12"
EXECUTABLE="EasyF12"
MIN_MACOS="11.0"
ARCHS="${ARCHS:-x86_64 arm64}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP" "$BUILD_DIR/Easy-F12.zip"
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
        Sources/EasyF12/*.swift
    binaries+=("$BUILD_DIR/$arch/$EXECUTABLE")
done

echo "→ Creo $APP_NAME.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

(cd "$BUILD_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "Easy-F12.zip")

echo "✓ Fatto: $APP"
echo "  Per installarla trascinala nella cartella Applicazioni."
