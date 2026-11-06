#!/usr/bin/env bash
# Construit build/MaxFtp.app (release, signature ad hoc avec les entitlements).
#
# Usage : Scripts/build-app.sh [debug|release]
#   UNIVERSAL=1 Scripts/build-app.sh   → binaire universel (Apple Silicon + Intel)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MaxFtp.app"

cd "$ROOT"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    # Une compilation par architecture, assemblées avec lipo (`--arch` multiple
    # exige Xcode ; ce chemin marche avec les seuls Command Line Tools).
    BIN="$ROOT/build/MaxFtp-universal"
    mkdir -p "$ROOT/build"
    SLICES=()
    for TRIPLE in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        swift build -c "$CONFIG" --product MaxFtp --triple "$TRIPLE"
        SLICES+=("$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/MaxFtp")
    done
    lipo -create "${SLICES[@]}" -output "$BIN"
else
    swift build -c "$CONFIG" --product MaxFtp
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/MaxFtp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MaxFtp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Icône générée par Scripts/make-icon.swift (à relancer si l'image source change).
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signature ad hoc (« - ») : suffisante en local. Pour distribuer, remplacer par
# un certificat Developer ID + `--options runtime`, puis notariser.
codesign --force --sign - --entitlements Resources/MaxFtp.entitlements "$APP"

echo "✅ $APP"
