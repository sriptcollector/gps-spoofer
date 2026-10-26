#!/usr/bin/env bash
# Builds "GPS Spoofer.app" and GPS.Spoofer_<version>_aarch64.dmg into dist/.
# The app carries the iPhone app prebuilt and unsigned (Resources/GPSSpoofer.ipa, made by
# scripts/build-ipa.sh; CI does) plus gs-helper, which signs it with the user's Apple ID. No Xcode
# needed on the user's Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
APP="dist/GPS Spoofer.app"

IPA=build/GPSSpoofer.ipa
[ -f "$IPA" ] || echo "warning: $IPA missing (run scripts/build-ipa.sh); the app won't be able to install" >&2

BIN="$(cd mac && swift build -c release --arch arm64 --show-bin-path)"
(cd mac && swift build -c release --arch arm64)
(cd mac/helper && cargo build --release --target aarch64-apple-darwin)
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GPSSpoofer" "$APP/Contents/MacOS/GPSSpoofer"
cp mac/helper/target/aarch64-apple-darwin/release/gs-helper "$APP/Contents/MacOS/gs-helper"
cp mac/Resources/AppIcon.icns "$APP/Contents/Resources/"
[ -f "$IPA" ] && cp "$IPA" "$APP/Contents/Resources/GPSSpoofer.ipa"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GPS Spoofer</string>
  <key>CFBundleDisplayName</key><string>GPS Spoofer</string>
  <key>CFBundleIdentifier</key><string>ai.toolbay.gpsspoofer.mac</string>
  <key>CFBundleExecutable</key><string>GPSSpoofer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"

DMG="dist/GPS.Spoofer_${VERSION}_aarch64.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "GPS Spoofer" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "$DMG"
