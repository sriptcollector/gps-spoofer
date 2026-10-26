import CryptoKit
import Foundation

/// Where everything lives: ~/Library/Application Support/GPS Spoofer
enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GPS Spoofer")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var components: URL { support.appendingPathComponent("idevice-\(Components.version)") }
    static var build: URL { support.appendingPathComponent("build") }
    static func pairing(_ udid: String) -> URL { support.appendingPathComponent("pairing-\(udid).plist") }

    /// The iPhone project shipped inside the .app (CI puts it in Resources/ios). `swift run` falls
    /// back to the repo checkout.
    static var iosProject: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ios"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("GPSSpoofer.xcodeproj").path) { return r }
        if let dev = ProcessInfo.processInfo.environment["GS_IOS_DIR"] { return URL(fileURLWithPath: dev) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../ios").standardized
    }
}

/// jkcoxson/idevice (MIT): the library the iPhone app uses to reach its own location service, and
/// the Mac tool that makes the pairing file. Prebuilt release, pinned by checksum.
enum Components {
    static let version = "v0.1.68"
    static let xcfZip = ("idevice-xcframework-v0.1.68.zip", "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7")
    static let toolsZip = ("idevice-tools-macos-arm-v0.1.68.zip", "fc4c2a74a3d2899bc33a7c2ed42d367e843b9dd6854bb3b1b257274b1ce712fa")

    static var toolPath: String { Paths.components.appendingPathComponent("tools/idevice-tools").path }
    static var xcframework: URL { Paths.components.appendingPathComponent("IDevice.xcframework") }

    static func tools(progress: ((Double) -> Void)? = nil) async throws -> String {
        if FileManager.default.isExecutableFile(atPath: toolPath) { return toolPath }
        let dir = Paths.components.appendingPathComponent("tools")
        try await fetch(toolsZip, into: dir, progress: progress)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            chmod(dir.appendingPathComponent(f).path, 0o755)
        }
        return toolPath
    }

    /// Slim iOS-only xcframework whose module is called IDeviceFFI (what the app imports).
    static func framework(progress: ((Double) -> Void)? = nil) async throws -> URL {
        let marker = xcframework.appendingPathComponent(".ok")
        if FileManager.default.fileExists(atPath: marker.path) { return xcframework }
        let tmp = Paths.support.appendingPathComponent("xcf-tmp")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await fetch(xcfZip, into: tmp, progress: progress)
        let src = tmp.appendingPathComponent("swift/IDevice.xcframework")
        var args = ["xcodebuild", "-create-xcframework"]
        for (slice, lib) in [("ios-arm64", "libidevice_ffi.a"), ("ios-arm64_x86_64-simulator", "idevice-ios-sim.a")] {
            let headers = src.appendingPathComponent("\(slice)/Headers")
            let map = headers.appendingPathComponent("module.modulemap")
            let text = try String(contentsOf: map, encoding: .utf8)
            try text.replacingOccurrences(of: "module IDevice ", with: "module IDeviceFFI ")
                .write(to: map, atomically: true, encoding: .utf8)
            args += ["-library", src.appendingPathComponent("\(slice)/\(lib)").path, "-headers", headers.path]
        }
        try? FileManager.default.removeItem(at: xcframework)
        let r = await Shell.xcrun(args + ["-output", xcframework.path])
        guard r.ok else { throw InstallError("Couldn't prepare the phone components.", r.tail) }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        return xcframework
    }

    private static func fetch(_ asset: (String, String), into dir: URL, progress: ((Double) -> Void)?) async throws {
        let url = URL(string: "https://github.com/jkcoxson/idevice/releases/download/\(version)/\(asset.0)")!
        let zip: URL
        do {
            zip = try await Download.file(url, progress: progress)
        } catch {
            throw InstallError("Couldn't reach the download. Check your internet connection and try again.", "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        let digest = try SHA256.hash(data: Data(contentsOf: zip, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == asset.1 else { throw InstallError("The download was damaged. Try again.", "sha256 \(digest)") }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard r.ok else { throw InstallError("Couldn't unpack the download. Try again.", r.tail) }
    }
}

struct InstallError: Error {
    let message: String
    let details: String
    init(_ message: String, _ details: String = "") { self.message = message; self.details = details }
}

/// URLSession download with a progress callback.
enum Download {
    static func file(_ url: URL, progress: ((Double) -> Void)?) async throws -> URL {
        let delegate = Delegate(progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            delegate.done = { cont.resume(with: $0) }
            session.downloadTask(with: url).resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: ((Double) -> Void)?
        var done: ((Result<URL, Error>) -> Void)?
        init(_ p: ((Double) -> Void)?) { progress = p }

        func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
            if e > 0 { progress?(Double(w) / Double(e)) }
        }
        func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            do {
                if let h = t.response as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
                try FileManager.default.moveItem(at: loc, to: keep)
                done?(.success(keep))
            } catch { done?(.failure(error)) }
            done = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if let e { done?(.failure(e)); done = nil }
        }
    }
}

/// The one-tap install: components → build with the user's team → install → pair → open.
@MainActor
final class Installer: ObservableObject {
    @Published var running = false
    @Published var stage = ""
    @Published var progress: Double?   // nil = indeterminate
    @Published var error: InstallError?
    @Published var note: String?       // a non-fatal follow-up for the user
    @Published var showDetails = false

    func install(_ checks: Checks) async {
        guard let phone = checks.phone, let team = checks.team, let bundle = checks.bundleID else { return }
        running = true; error = nil; note = nil
        defer { running = false; progress = nil; stage = "" }
        do {
            stage = "Getting the phone components…"
            let xcf = try await Components.framework { p in Task { @MainActor in self.progress = p } }
            progress = nil
            let tools = try await Components.tools()

            stage = "Building GPS Spoofer with your Apple account…"
            let app = try await build(xcf: xcf, team: team, bundle: bundle, udid: phone.udid)

            stage = "Installing on \(phone.name)…"
            let inst = await Shell.devicectl(["device", "install", "app", "--device", phone.identifier, app.path]).0
            guard inst.ok else { throw friendly(inst, fallback: "Couldn't install on your iPhone. Unlock it and try again.") }

            stage = "Pairing GPS Spoofer with your iPhone…"
            let pairing = Paths.pairing(phone.udid)
            if !FileManager.default.fileExists(atPath: pairing.path) {
                let r = await Shell.run(tools, ["remotepairing_lockdown", "pair", "GPS Spoofer", pairing.path])
                guard r.ok, FileManager.default.fileExists(atPath: pairing.path) else {
                    throw InstallError("Couldn't pair with your iPhone. Unlock it, keep it plugged in, and try again.", r.tail)
                }
            }
            let copy = await Shell.devicectl(["device", "copy", "to", "--device", phone.identifier,
                                              "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                                              "--source", pairing.path, "--destination", "Documents/pairing.plist"]).0
            guard copy.ok else { throw InstallError("Couldn't finish pairing. Try again.", copy.tail) }

            stage = "Opening GPS Spoofer…"
            let launch = await Shell.devicectl(["device", "process", "launch", "--terminate-existing",
                                                "--device", phone.identifier, bundle]).0
            if !launch.ok {
                let t = launch.tail.lowercased()
                if team.free || t.contains("trust") || t.contains("profile") || t.contains("security") {
                    note = "Installed. One more step on your iPhone: Settings › General › VPN & Device Management › tap your Apple account › Trust. Then open GPS Spoofer."
                } else {
                    note = "Installed. Unlock your iPhone and open GPS Spoofer."
                }
            }
        } catch let e as InstallError {
            error = e
        } catch {
            self.error = InstallError("Something went wrong. Try again.", "\(error)")
        }
        await checks.refresh()
    }

    private func build(xcf: URL, team: Team, bundle: String, udid: String) async throws -> URL {
        let fm = FileManager.default
        let work = Paths.build.appendingPathComponent("ios")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: Paths.build, withIntermediateDirectories: true)
        try fm.copyItem(at: Paths.iosProject, to: work)
        let vendor = work.appendingPathComponent("Vendor")
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: vendor.appendingPathComponent("IDevice.xcframework"), withDestinationURL: xcf)

        let dd = Paths.build.appendingPathComponent("DerivedData")
        let r = await Shell.xcrun([
            "xcodebuild", "-project", work.appendingPathComponent("GPSSpoofer.xcodeproj").path,
            "-scheme", "GPSSpoofer", "-configuration", "Debug",
            "-destination", "id=\(udid)", "-derivedDataPath", dd.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team.id)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundle)",
            "SWIFT_OPTIMIZATION_LEVEL=-O", "build", "-quiet",
        ])
        let app = dd.appendingPathComponent("Build/Products/Debug-iphoneos/GPSSpoofer.app")
        guard r.ok, fm.fileExists(atPath: app.path) else {
            throw friendly(r, fallback: "Xcode couldn't build the app. Check your Apple account in Xcode › Settings › Accounts and try again.")
        }
        if let exp = Self.expiry(app.appendingPathComponent("embedded.mobileprovision")) {
            UserDefaults.standard.set(exp, forKey: "expiry.\(bundle)")
        }
        return app
    }

    static func expiry(_ profile: URL) -> Date? {
        guard let data = try? Data(contentsOf: profile),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                                      format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Plain-language versions of the errors people actually hit.
    private func friendly(_ r: Shell.Result, fallback: String) -> InstallError {
        let t = (r.out + r.err).lowercased()
        let msg: String
        if t.contains("maximum number of apps") || t.contains("too many apps") {
            msg = "Free Apple accounts can have 3 developer apps on a phone at once. Delete one you installed from Xcode, then try again."
        } else if t.contains("no account") || t.contains("no signing certificate") || t.contains("requires a development team")
                    || t.contains("sign in") {
            msg = "Xcode couldn't sign the app. Open Xcode › Settings › Accounts, make sure your Apple ID is signed in, then try again."
        } else if t.contains("locked") {
            msg = "Your iPhone is locked. Unlock it and try again."
        } else if t.contains("developer mode") {
            msg = "Developer Mode is off on your iPhone. Turn it on and try again."
        } else if t.contains("device support") || t.contains("not available") && t.contains("platform") {
            msg = "Xcode needs the iOS support files. Open Xcode once, let it finish downloading, then try again."
        } else {
            msg = fallback
        }
        return InstallError(msg, r.tail)
    }
}
