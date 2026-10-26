# GPS Spoofer

Move your iPhone's location anywhere: a custom phone app you install from your Mac. No jailbreak.
Part of [Toolbay](https://toolbay.ai).

<img src="assets/gps-spoofer-512.png" width="96" alt="">

## How you use it

1. Install **GPS Spoofer** from Toolbay (or open the `.dmg` from Releases).
2. The Mac window has a light for each requirement. Get them all green:
   - **Xcode** (free, Mac App Store). It builds the app for your phone.
   - **Apple account in Xcode**: Xcode › Settings › Accounts. A free Apple ID works; the app then
     lasts 7 days before you press Install again. A paid developer account makes it last a year.
   - **iPhone plugged in**, **trusts this Mac**, **Developer Mode on**.
3. Press **Install on iPhone**. It builds the app with your account, installs it, and pairs it with
   the phone.
4. On the iPhone: get **LocalDevVPN** (free, App Store; the Mac shows a QR code), connect it, open
   GPS Spoofer. The onboarding walks through the same checks with live lights.

Then tap anywhere on the map to teleport, or add stops to walk, drive or sail between them.

## How it works

```
GPS Spoofer (map) ──► LocalDevVPN tunnel (10.7.0.1) ──► iPhone's developer location service ──► every app
```

The phone's developer location service is the same one Xcode uses to test apps. iOS doesn't let an
app reach it directly, so LocalDevVPN loops the connection back to the phone. The Mac makes a pairing
file once (over the cable) and copies it into the app; after that the phone needs no Mac.

## Repo

| path | what |
|---|---|
| `ios/` | the iPhone app (SwiftUI). `project.yml` → `xcodegen` → `GPSSpoofer.xcodeproj` |
| `mac/` | the Mac installer window (SwiftUI, SwiftPM) |
| `scripts/package-mac.sh` | builds `GPS Spoofer.app` + `.dmg`, with the iPhone project inside |
| `scripts/fetch-idevice.sh` | gets the idevice library for local iPhone builds |
| `toolbay.json` | what the Toolbay hub installs; CI fills in the release asset, size and sha256 |

Develop: `brew install xcodegen && xcodegen generate --spec ios/project.yml --project ios && scripts/fetch-idevice.sh`,
then open `ios/GPSSpoofer.xcodeproj`. Mac window: `cd mac && swift run`.
Release: push a `v*` tag; CI compiles both apps and publishes the `.dmg` and `toolbay.json`.

## Credits

Talks to the phone with [idevice](https://github.com/jkcoxson/idevice) (MIT) by jkcoxson.
[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) is a separate free app by its own developer.

Only spoof the location of devices you own. MIT licensed.
