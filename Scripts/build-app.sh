#!/usr/bin/env bash
# Construit build/MaxFtp.app (release, signature ad hoc avec les entitlements).
#
# Usage : Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MaxFtp.app"

cd "$ROOT"
swift build -c "$CONFIG" --product MaxFtp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MaxFtp"

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
