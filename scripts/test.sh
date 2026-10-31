#!/bin/bash
# Esegue le prove automatiche (Tests/Prove.swift) con un Gmail simulato: nessun accesso a Gmail vero.
# Nota: crea e poi cancella una voce di prova nel Portachiavi.
set -euo pipefail

cd "$(dirname "$0")/.."

CARTELLA="$(mktemp -d)"
trap 'rm -rf "$CARTELLA"' EXIT

# Il codice "sciolto" delle prove è ammesso solo in un file chiamato main.swift.
cp Tests/Prove.swift "$CARTELLA/main.swift"
xcrun swiftc -swift-version 5 -module-name EasyF24 \
    $(ls Sources/EasyF24/*.swift | grep -v EasyF24App.swift) "$CARTELLA/main.swift" \
    -o "$CARTELLA/prove"
"$CARTELLA/prove" "$CARTELLA/dati"
