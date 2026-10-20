#!/bin/bash
# Packs dist/MacCleaner.app into dist/MacCleaner-<version>.dmg with an Applications shortcut to drag onto.
#
#   NOTARY_PROFILE=<keychain profile> scripts/make-dmg.sh   # also notarizes and staples (needs a Developer ID build)
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID> --password <app-specific password>
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/MacCleaner.app"
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/MacCleaner-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "MacCleaner $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null

SIGNATURE="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ -n "$SIGNATURE" ]; then
    codesign --force --timestamp --sign "$SIGNATURE" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
