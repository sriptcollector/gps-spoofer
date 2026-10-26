# GPS Spoofer

Move your iPhone's location anywhere: a custom phone app you install from your Mac. No jailbreak.
Part of [Toolbay](https://toolbay.ai).

<img src="assets/gps-spoofer-512.png" width="96" alt="">

## How you use it

1. Install **GPS Spoofer** from Toolbay (or open the `.dmg` from Releases).
2. The Mac window has a light for each requirement. Get them all green:
   - **Apple account**: press Sign in and use your Apple ID. A free one works; the app then lasts
     7 days before you press Install again. A paid developer account makes it last a year.
     **No Xcode needed.**
   - **iPhone plugged in**, **trusts this Mac**, **Developer Mode on**.
3. Press **Install on iPhone**. It signs the app with your Apple ID, installs it, and pairs it with
   the phone. The first time, the iPhone may say *Untrusted Developer*: Settings › General ›
   VPN & Device Management › your Apple ID › Trust.
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

Installing needs no Xcode. CI compiles the iPhone app once, unsigned, and ships it inside the Mac app.
`gs-helper` (Rust) signs it with your Apple ID the way Xcode would: it signs in to Apple (2FA
included), registers the phone, gets a development certificate and profile, then installs over USB.
Your password stays in the Mac's keychain and is only sent to Apple.

## Repo

| path | what |
|---|---|
| `ios/` | the iPhone app (SwiftUI). `project.yml` → `xcodegen` → `GPSSpoofer.xcodeproj` |
| `mac/` | the Mac installer window (SwiftUI, SwiftPM) |
| `mac/helper/` | `gs-helper` (Rust): Apple ID signing + install ([isideload](https://github.com/nab138/isideload)), phone checks and pairing ([idevice](https://github.com/jkcoxson/idevice)) |
| `scripts/build-ipa.sh` | compiles the iPhone app unsigned into `build/GPSSpoofer.ipa` (needs Xcode; CI only) |
| `scripts/package-mac.sh` | builds `GPS Spoofer.app` + `.dmg`, with gs-helper and the `.ipa` inside |
| `scripts/fetch-idevice.sh` | gets the idevice library for iPhone builds |
| `toolbay.json` | what the Toolbay hub installs; CI fills in the release asset, size and sha256 |

Develop: `brew install xcodegen && xcodegen generate --spec ios/project.yml --project ios && scripts/fetch-idevice.sh`,
then open `ios/GPSSpoofer.xcodeproj`. Mac window: `(cd mac/helper && cargo build --release) && scripts/build-ipa.sh && cd mac && swift run`.
Release: push a `v*` tag; CI compiles both apps and publishes the `.dmg` and `toolbay.json`.

## Credits

Talks to the phone with [idevice](https://github.com/jkcoxson/idevice) (MIT) by jkcoxson, and signs with
[isideload](https://github.com/nab138/isideload) (MIT) by nab138. Apple sign-in uses the public anisette
server isideload defaults to (ani.jkcoxson.com).
[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) is a separate free app by its own developer.

Only spoof the location of devices you own. MIT licensed.
