#!/usr/bin/env bash
# Compiles the iPhone app unsigned for any iPhone and zips it as build/GPSSpoofer.ipa. Needs Xcode,
# but only here/in CI: the Mac app signs this .ipa with the user's Apple ID at install time.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet --spec ios/project.yml --project ios
scripts/fetch-idevice.sh
xcodebuild -project ios/GPSSpoofer.xcodeproj -scheme GPSSpoofer -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios \
  CODE_SIGNING_ALLOWED=NO SWIFT_OPTIMIZATION_LEVEL=-O build -quiet
APP=build/ios/Build/Products/Debug-iphoneos/GPSSpoofer.app
rm -rf build/ipa build/GPSSpoofer.ipa && mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry ../GPSSpoofer.ipa Payload)
rm -rf build/ipa
echo build/GPSSpoofer.ipa
