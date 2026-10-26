import Foundation

/// Where everything lives: ~/Library/Application Support/GPS Spoofer
enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPS Spoofer")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// Apple sign-in state and the signing certificate's key. Only this user can read it.
    static let signing: URL = {
        let u = support.appendingPathComponent("signing")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return u
    }()
    static func pairing(_ udid: String) -> URL { support.appendingPathComponent("pairing-\(udid).plist") }

    /// The iPhone app, compiled by CI and shipped inside the .app (Resources/GPSSpoofer.ipa).
    /// `swift run` falls back to GS_IPA or the repo's build/GPSSpoofer.ipa.
    static var ipa: URL {
        if let r = Bundle.main.url(forResource: "GPSSpoofer", withExtension: "ipa") { return r }
        if let dev = ProcessInfo.processInfo.environment["GS_IPA"] { return URL(fileURLWithPath: dev) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../build/GPSSpoofer.ipa").standardized
    }
}

struct InstallError: Error {
    let message: String
    let details: String
    init(_ message: String, _ details: String = "") { self.message = message; self.details = details }
}

/// The one-tap install: sign with the user's Apple ID → install → pair. All in gs-helper.
@MainActor
final class Installer: ObservableObject {
    @Published var running = false
    @Published var stage = ""
    @Published var progress: Double?   // nil = indeterminate
    @Published var error: InstallError?
    @Published var note: String?       // a non-fatal follow-up for the user
    @Published var showDetails = false

    func install(_ checks: Checks) async {
        guard let phone = checks.phone, let team = checks.team else { return }
        guard let creds = checks.credentials else { checks.showSignIn = true; return }
        guard FileManager.default.fileExists(atPath: Paths.ipa.path) else {
            error = InstallError("GPS Spoofer is missing the iPhone app. Reinstall it.", Paths.ipa.path)
            return
        }
        running = true; error = nil; note = nil; stage = "Starting…"
        defer { running = false; progress = nil; stage = "" }

        let r = await Helper.call(["install", "--data", Paths.signing.path, "--udid", phone.udid,
                                   "--ipa", Paths.ipa.path, "--team", team.id,
                                   "--pairing", Paths.pairing(phone.udid).path],
                                  input: creds) { [weak self] ev, run in
            if checks.handle(ev, run) { return }
            if let s = ev["stage"] as? String { self?.stage = s }
            if ev.keys.contains("progress") { self?.progress = ev["progress"] as? Double }
        }
        checks.showSignIn = false
        guard r.ok else {
            error = r.failure
            await checks.refresh()
            return
        }
        let bundle = r.body["bundle"] as? String ?? checks.bundleID ?? ""
        if let s = r.body["expiry"] as? String, let exp = ISO8601DateFormatter().date(from: s) {
            UserDefaults.standard.set(exp, forKey: "expiry.\(bundle)")
        }
        note = "Installed. Open GPS Spoofer on your iPhone. If it says Untrusted Developer: Settings › General › VPN & Device Management › tap your Apple ID › Trust."
        await checks.refresh()
    }
}
