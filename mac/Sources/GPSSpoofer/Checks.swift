import AppKit
import Foundation

/// One status light in the window.
struct Light: Equatable {
    enum State: Equatable { case ok, bad, waiting, checking }
    var state: State
    var title: String
    var detail: String

    static func waiting(_ title: String, _ detail: String) -> Light { .init(state: .waiting, title: title, detail: detail) }
}

struct Team: Hashable, Identifiable {
    let id: String      // Apple team ID
    let name: String
    let free: Bool
}

struct Phone: Equatable {
    let identifier: String   // devicectl id
    let udid: String
    let name: String
    let paired: Bool
    let devMode: Bool?
}

/// Everything the window shows, re-checked on a timer. All the probing happens here; the view only
/// reads the lights.
@MainActor
final class Checks: ObservableObject {
    static let vpnStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    @Published var xcode = Light.waiting("Xcode", "Checking…")
    @Published var account = Light.waiting("Apple account in Xcode", "Waiting for Xcode")
    @Published var connected = Light.waiting("iPhone plugged in", "Waiting for Xcode")
    @Published var trusted = Light.waiting("iPhone trusts this Mac", "Waiting for iPhone")
    @Published var devMode = Light.waiting("Developer Mode on", "Waiting for iPhone")

    @Published var appOnPhone = Light.waiting("GPS Spoofer on iPhone", "Not installed yet")
    @Published var vpnOnPhone = Light.waiting("LocalDevVPN on iPhone", "Waiting for iPhone")
    @Published var link = Light.waiting("Connected", "Waiting for the app")

    @Published var xcodeState: XcodeState = .missing
    @Published var teams: [Team] = []
    @Published var phone: Phone?
    @Published var busy: String?   // an action button is running (shows a spinner on that row)

    @Published var selectedTeam: String = UserDefaults.standard.string(forKey: "team") ?? "" {
        didSet { UserDefaults.standard.set(selectedTeam, forKey: "team") }
    }

    enum XcodeState { case missing, needsSetup, ready }

    var team: Team? { teams.first { $0.id == selectedTeam } ?? teams.first }
    var bundleID: String? { team.map { "ai.toolbay.gpsspoofer.\($0.id.lowercased())" } }
    var readyToInstall: Bool {
        [xcode, account, connected, trusted, devMode].allSatisfy { $0.state == .ok }
    }

    private var timer: Timer?
    private var refreshing = false
    private var lastPhoneScan = Date.distantPast

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        await checkXcode()
        guard xcodeState == .ready else {
            account = .waiting("Apple account in Xcode", "Waiting for Xcode")
            connected = .waiting("iPhone plugged in", "Waiting for Xcode")
            trusted = .waiting("iPhone trusts this Mac", "Waiting for iPhone")
            devMode = .waiting("Developer Mode on", "Waiting for iPhone")
            return
        }
        checkAccount()
        await checkPhone()
        await checkAfterInstall()
    }

    // MARK: Xcode

    static func findXcode() -> String? {
        let fm = FileManager.default
        let apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .sorted { a, b in (a == "Xcode.app") || (b != "Xcode.app" && a > b) }
        return apps.map { "/Applications/\($0)" }
            .first { fm.fileExists(atPath: "\($0)/Contents/Developer/usr/bin/xcodebuild") }
    }

    private func checkXcode() async {
        guard let path = Self.findXcode() else {
            xcodeState = .missing
            Shell.developerDir = nil
            xcode = .init(state: .bad, title: "Xcode",
                          detail: "Install Xcode from the Mac App Store (free). It builds the app for your iPhone.")
            return
        }
        Shell.developerDir = "\(path)/Contents/Developer"
        if xcodeState != .ready {
            let license = await Shell.run("\(path)/Contents/Developer/usr/bin/xcodebuild", ["-license", "check"])
            let first = await Shell.run("\(path)/Contents/Developer/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"])
            if !license.ok || !first.ok {
                xcodeState = .needsSetup
                xcode = .init(state: .bad, title: "Xcode",
                              detail: "Xcode needs to finish setting up. Click Finish setup and enter your Mac password.")
                return
            }
        }
        xcodeState = .ready
        xcode = .init(state: .ok, title: "Xcode", detail: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    func finishXcodeSetup() async {
        guard let path = Self.findXcode() else { return }
        busy = "xcode"
        let xb = "'\(path)/Contents/Developer/usr/bin/xcodebuild'"
        _ = await Shell.asAdmin("\(xb) -license accept && \(xb) -runFirstLaunch")
        busy = nil
        xcodeState = .missing   // force a full re-check
        await refresh()
    }

    // MARK: Apple account (Xcode › Settings › Accounts)

    private func checkAccount() {
        let d = UserDefaults(suiteName: "com.apple.dt.Xcode")
        var found: [Team] = []
        for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
            guard let byAccount = d?.dictionary(forKey: key) else { continue }
            for case let list as [[String: Any]] in byAccount.values {
                for t in list {
                    guard let id = t["teamID"] as? String, !found.contains(where: { $0.id == id }) else { continue }
                    let free = (t["isFreeProvisioningTeam"] as? Bool) ?? ((t["isFreeProvisioningTeam"] as? Int) == 1)
                    found.append(Team(id: id, name: (t["teamName"] as? String) ?? id, free: free))
                }
            }
        }
        // Paid teams first: their apps last a year instead of a week.
        teams = found.sorted { ($0.free ? 1 : 0, $0.name) < ($1.free ? 1 : 0, $1.name) }
        if let t = team {
            account = .init(state: .ok, title: "Apple account in Xcode",
                            detail: t.free ? "\(t.name) · free account: reinstall every 7 days"
                                           : "\(t.name) · app lasts a year")
        } else {
            account = .init(state: .bad, title: "Apple account in Xcode",
                            detail: "Open Xcode › Settings › Accounts, click +, and sign in with your Apple ID (free is fine).")
        }
    }

    func openXcodeAccounts() {
        guard let path = Self.findXcode() else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }

    // MARK: iPhone

    private func checkPhone() async {
        let (_, res) = await Shell.devicectl(["list", "devices"])
        let devices = (res?["devices"] as? [[String: Any]]) ?? []
        let phones: [(Phone, Bool)] = devices.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let dp = d["deviceProperties"] as? [String: Any] ?? [:]
            let cp = d["connectionProperties"] as? [String: Any] ?? [:]
            guard (hw["platform"] as? String) == "iOS" else { return nil }
            let wired = (cp["transportType"] as? String) == "wired"
            let reachable = wired || ((cp["tunnelState"] as? String).map { $0 != "unavailable" } ?? false)
            guard reachable else { return nil }
            let dm = (dp["developerModeStatus"] as? String).map { $0 == "enabled" }
            return (Phone(identifier: d["identifier"] as? String ?? "", udid: hw["udid"] as? String ?? "",
                          name: dp["name"] as? String ?? "iPhone",
                          paired: (cp["pairingState"] as? String) == "paired", devMode: dm), wired)
        }
        guard let pick = phones.first(where: { $0.1 }) ?? phones.first else {
            phone = nil
            connected = .init(state: .bad, title: "iPhone plugged in",
                              detail: "Plug your iPhone into this Mac with a cable and unlock it.")
            trusted = .waiting("iPhone trusts this Mac", "Waiting for iPhone")
            devMode = .waiting("Developer Mode on", "Waiting for iPhone")
            return
        }
        var p = pick.0
        connected = .init(state: .ok, title: "iPhone plugged in", detail: p.name)
        guard p.paired else {
            phone = p
            trusted = .init(state: .bad, title: "iPhone trusts this Mac",
                            detail: "Unlock your iPhone and tap Trust, then enter your passcode.")
            devMode = .waiting("Developer Mode on", "Waiting for Trust")
            return
        }
        trusted = .init(state: .ok, title: "iPhone trusts this Mac", detail: "Trusted")
        if p.devMode == nil {
            let (_, det) = await Shell.devicectl(["device", "info", "details", "--device", p.identifier])
            let dp = det?["deviceProperties"] as? [String: Any]
            p = Phone(identifier: p.identifier, udid: p.udid, name: p.name, paired: true,
                      devMode: (dp?["developerModeStatus"] as? String).map { $0 == "enabled" })
        }
        phone = p
        devMode = p.devMode == true
            ? .init(state: .ok, title: "Developer Mode on", detail: "On")
            : .init(state: .bad, title: "Developer Mode on",
                    detail: "On iPhone: Settings › Privacy & Security › Developer Mode › On. It restarts; tap Turn On after.")
    }

    func askTrust() async {
        guard let p = phone else { return }
        busy = "trust"
        _ = await Shell.devicectl(["manage", "pair", "--device", p.identifier])
        busy = nil
        await refresh()
    }

    /// Developer Mode stays hidden in Settings until a Mac asks for it.
    func revealDevMode() async {
        guard phone != nil else { return }
        busy = "devmode"
        if let tools = try? await Components.tools() {
            _ = await Shell.run(tools, ["amfi", "show"])   // the plugged-in phone
        }
        busy = nil
    }

    // MARK: after install

    private func checkAfterInstall() async {
        guard let p = phone, p.paired, p.devMode == true, let bundle = bundleID else {
            appOnPhone = .waiting("GPS Spoofer on iPhone", "Not installed yet")
            vpnOnPhone = .waiting("LocalDevVPN on iPhone", "Waiting for iPhone")
            link = .waiting("Connected", "Waiting for the app")
            return
        }
        // The app list is slow; every third tick is plenty.
        guard Date().timeIntervalSince(lastPhoneScan) > 8 || appOnPhone.state == .waiting else { return }
        lastPhoneScan = Date()

        let (_, res) = await Shell.devicectl(["device", "info", "apps", "--device", p.identifier])
        let apps = (res?["apps"] as? [[String: Any]]) ?? []
        let ids = apps.compactMap { $0["bundleIdentifier"] as? String }
        let names = apps.compactMap { $0["name"] as? String }

        let haveApp = ids.contains(bundle)
        let expiry = UserDefaults.standard.object(forKey: "expiry.\(bundle)") as? Date
        if haveApp {
            var detail = "Installed"
            if let expiry {
                let f = DateFormatter(); f.dateStyle = .medium
                detail = expiry < Date() ? "Expired. Press Install again." : "Works until \(f.string(from: expiry)). Press Install again before then."
            }
            appOnPhone = .init(state: expiry.map { $0 > Date() } ?? true ? .ok : .bad, title: "GPS Spoofer on iPhone", detail: detail)
        } else {
            appOnPhone = .init(state: .waiting, title: "GPS Spoofer on iPhone", detail: "Not installed yet")
        }

        let haveVPN = names.contains { $0.localizedCaseInsensitiveContains("LocalDevVPN") }
            || ids.contains { $0.localizedCaseInsensitiveContains("localdevvpn") }
        vpnOnPhone = haveVPN
            ? .init(state: .ok, title: "LocalDevVPN on iPhone", detail: "Installed")
            : .init(state: .bad, title: "LocalDevVPN on iPhone",
                    detail: "Free on the App Store. Scan the code with your iPhone camera to get it.")

        guard haveApp else { link = .waiting("Connected", "Waiting for the app"); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gs-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = await Shell.devicectl(["device", "copy", "from", "--device", p.identifier, "--domain-type", "appDataContainer",
                                   "--domain-identifier", bundle, "--source", "Documents/status.json",
                                   "--destination", tmp.path])
        guard let data = try? Data(contentsOf: tmp),
              let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            link = .init(state: .bad, title: "Connected", detail: "Open GPS Spoofer on your iPhone once.")
            return
        }
        let paired = s["paired"] as? Bool ?? false
        let vpn = s["vpnConnected"] as? Bool ?? false
        let live = s["live"] as? Bool ?? false
        let age = (s["updated"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }.map { Date().timeIntervalSince($0) }
        let stale = (age ?? .infinity) > 120 ? " (as of the last time GPS Spoofer was open)" : ""
        if !paired {
            link = .init(state: .bad, title: "Connected", detail: "Not paired yet. Press Install again.")
        } else if !vpn {
            link = .init(state: .bad, title: "Connected",
                         detail: "Open LocalDevVPN on your iPhone and tap Connect\(stale).")
        } else {
            link = .init(state: .ok, title: "Connected",
                         detail: (live ? "Spoofing now" : "Ready. Pick a spot in GPS Spoofer") + stale)
        }
    }
}
