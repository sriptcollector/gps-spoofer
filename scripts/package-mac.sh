#!/usr/bin/env bash
# Builds "GPS Spoofer.app" and GPS.Spoofer_<version>_aarch64.dmg into dist/.
# The iPhone project ships inside the app (Resources/ios); generate it first with
# `xcodegen generate --spec ios/project.yml --project ios` (CI does).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
APP="dist/GPS Spoofer.app"

[ -d ios/GPSSpoofer.xcodeproj ] || echo "warning: ios/GPSSpoofer.xcodeproj missing; the app won't be able to install until it's generated" >&2

BIN="$(cd mac && swift build -c release --arch arm64 --show-bin-path)"
(cd mac && swift build -c release --arch arm64)
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GPSSpoofer" "$APP/Contents/MacOS/GPSSpoofer"
cp mac/Resources/AppIcon.icns "$APP/Contents/Resources/"
rsync -a --exclude Vendor --exclude '*.xcuserstate' --exclude xcuserdata ios/ "$APP/Contents/Resources/ios/"
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
