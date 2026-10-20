#!/bin/bash
# Builds MacCleaner.app (universal: Apple silicon + Intel) into dist/.
#
#   VERSION=1.0.0 BUILD=1 scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh   # signed for distribution
#
# Without SIGN_IDENTITY the app is ad-hoc signed: it runs on this Mac, and on other Macs after
# right-click → Open (Gatekeeper cannot verify the developer).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/MacCleaner.app"

echo "▸ Building MacCleaner $VERSION ($BUILD)"
for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    swift build -c release --triple "$triple" --product MacCleaner
done

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    .build/arm64-apple-macosx/release/MacCleaner \
    .build/x86_64-apple-macosx/release/MacCleaner \
    -output "$APP/Contents/MacOS/MacCleaner"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "▸ Signing ($([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/MacCleaner"))"
