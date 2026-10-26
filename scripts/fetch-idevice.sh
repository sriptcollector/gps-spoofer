#!/usr/bin/env bash
# Puts the iOS-only IDevice.xcframework (module renamed to IDeviceFFI) in ios/Vendor for local/CI
# builds. The Mac app does the same thing itself at install time (mac/Sources/GPSSpoofer/Installer.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
VER=v0.1.68
SHA=c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7
OUT=ios/Vendor/IDevice.xcframework
[ -f "$OUT/.ok" ] && exit 0
T=$(mktemp -d)
curl -fsSL -o "$T/x.zip" "https://github.com/jkcoxson/idevice/releases/download/$VER/idevice-xcframework-$VER.zip"
echo "$SHA  $T/x.zip" | shasum -a 256 -c --status
ditto -x -k "$T/x.zip" "$T/x"
SRC="$T/x/swift/IDevice.xcframework"
for s in ios-arm64 ios-arm64_x86_64-simulator; do
  sed -i '' 's/^module IDevice /module IDeviceFFI /' "$SRC/$s/Headers/module.modulemap"
done
rm -rf "$OUT"; mkdir -p ios/Vendor
xcodebuild -create-xcframework \
  -library "$SRC/ios-arm64/libidevice_ffi.a" -headers "$SRC/ios-arm64/Headers" \
  -library "$SRC/ios-arm64_x86_64-simulator/idevice-ios-sim.a" -headers "$SRC/ios-arm64_x86_64-simulator/Headers" \
  -output "$OUT"
touch "$OUT/.ok"
rm -rf "$T"
