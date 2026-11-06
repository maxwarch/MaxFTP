#!/usr/bin/env bash
# Prépare la release téléchargeable : build/MaxFtp-<version>.dmg (app universelle).
#
# Le .dmg contient MaxFtp.app et un raccourci vers Applications (glisser-déposer).
# L'app est signée ad hoc, pas notarisée : au premier lancement, macOS demande de
# l'autoriser (Réglages Système › Confidentialité et sécurité › « Ouvrir quand même »).
# Pour une app notarisée : certificat Developer ID, puis `codesign --options runtime`
# et `xcrun notarytool submit … --wait` + `xcrun stapler staple`.
#
# Usage : Scripts/package-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="$ROOT/build/MaxFtp-$VERSION.dmg"
STAGING="$(mktemp -d -t maxftp-dmg)"
trap 'rm -rf "$STAGING"' EXIT

UNIVERSAL=1 Scripts/build-app.sh release
lipo -archs build/MaxFtp.app/Contents/MacOS/MaxFtp

cp -R build/MaxFtp.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "MaxFtp $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG"
echo "✅ $DMG"
