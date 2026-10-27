#!/bin/bash
# Builds Sempre.app (universal: Apple Silicon + Intel), packs build/Sempre-<version>.zip
# and installs the app to ~/Applications.
#
# Signing (optional):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  sign for distribution (hardened runtime)
#   NOTARY_PROFILE=sempre                                    also notarize + staple; create the profile once with
#     xcrun notarytool store-credentials sempre --apple-id <id> --team-id <TEAMID> --password <app-specific password>
# Without SIGN_IDENTITY the app is ad-hoc signed: fine on this Mac, other Macs need right-click › Open.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.1
BUILD=2
IDENTITY="${SIGN_IDENTITY:--}"

APP=build/Sempre.app
ZIP="build/Sempre-$VERSION.zip"
rm -rf "$APP" "$ZIP"
mkdir -p build
# Newer SwiftPM writes every triple to the same bin path, so copy each slice out right after its build.
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0"
  cp "$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Sempre" "build/Sempre-$ARCH"
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -create -output "$APP/Contents/MacOS/Sempre" build/Sempre-arm64 build/Sempre-x86_64
rm build/Sempre-arm64 build/Sempre-x86_64
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sempre</string>
  <key>CFBundleIdentifier</key><string>com.franzh.sempre</string>
  <key>CFBundleExecutable</key><string>Sempre</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Franz Heinfling</string>
</dict>
</plist>
PLIST

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
for ARCH in arm64 x86_64; do lipo "$APP/Contents/MacOS/Sempre" -verify_arch "$ARCH"; done

ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "Packed $ZIP"

mkdir -p ~/Applications
rm -rf ~/Applications/Sempre.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Sempre.app"
