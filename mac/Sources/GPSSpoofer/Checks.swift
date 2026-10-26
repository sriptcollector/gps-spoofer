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

struct Team: Hashable, Identifiable, Codable {
    let id: String      // Apple team ID
    let name: String
}

struct Phone: Equatable {
    let udid: String
    let name: String
    let paired: Bool
    let devMode: Bool?
}

/// A question the helper is waiting on: Apple's two-factor code.
struct CodePrompt: Equatable {
    var sms: Bool
    var lastError: String?
}

/// Everything the window shows, re-checked on a timer. All the probing happens here; the view only
/// reads the lights.
@MainActor
final class Checks: ObservableObject {
    static let vpnStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    @Published var account = Light.waiting("Apple account", "Checking…")
    @Published var connected = Light.waiting("iPhone plugged in", "Checking…")
    @Published var trusted = Light.waiting("iPhone trusts this Mac", "Waiting for iPhone")
    @Published var devMode = Light.waiting("Developer Mode on", "Waiting for iPhone")

    @Published var appOnPhone = Light.waiting("GPS Spoofer on iPhone", "Not installed yet")
    @Published var vpnOnPhone = Light.waiting("LocalDevVPN on iPhone", "Waiting for iPhone")
    @Published var link = Light.waiting("Connected", "Waiting for the app")

    @Published var phone: Phone?
    @Published var busy: String?   // an action button is running (shows a spinner on that row)

    // Apple account: email + teams in defaults, password in the keychain.
    @Published var email: String = UserDefaults.standard.string(forKey: "appleID") ?? ""
    @Published var teams: [Team] = (UserDefaults.standard.data(forKey: "teams"))
        .flatMap { try? JSONDecoder().decode([Team].self, from: $0) } ?? []
    @Published var selectedTeam: String = UserDefaults.standard.string(forKey: "team") ?? "" {
        didSet { UserDefaults.standard.set(selectedTeam, forKey: "team") }
    }

    // Sign-in sheet state.
    @Published var showSignIn = false
    @Published var signingIn = false
    @Published var signInError: InstallError?
    @Published var codePrompt: CodePrompt?
    private var pending: Helper.Run?

    var team: Team? { teams.first { $0.id == selectedTeam } ?? teams.first }
    /// isideload registers the app as <bundle id in the .ipa>.<team id>.
    var bundleID: String? { team.map { "ai.toolbay.gpsspoofer.\($0.id)" } }
    var credentials: [String: Any]? {
        guard !email.isEmpty, let pw = Keychain.password(for: email) else { return nil }
        return ["email": email, "password": pw]
    }
    var readyToInstall: Bool {
        [account, connected, trusted, devMode].allSatisfy { $0.state == .ok }
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

        checkAccount()
        await checkPhone()
        await checkAfterInstall()
    }

    // MARK: Apple account

    private func checkAccount() {
        if let t = team, credentials != nil {
            account = .init(state: .ok, title: "Apple account", detail: "\(email) · \(t.name)")
        } else {
            account = .init(state: .bad, title: "Apple account",
                            detail: "Sign in with your Apple ID (a free one works). It signs the app for your iPhone.")
        }
    }

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespaces)
        signingIn = true; signInError = nil; codePrompt = nil
        defer { signingIn = false; codePrompt = nil; pending = nil }
        let r = await Helper.call(["login", "--data", Paths.signing.path],
                                  input: ["email": email, "password": password]) { [weak self] ev, run in
            self?.handle(ev, run)
        }
        guard r.ok else { signInError = r.failure; return }
        let found = (r.body["teams"] as? [[String: Any]] ?? []).compactMap { t -> Team? in
            guard let id = t["id"] as? String else { return nil }
            return Team(id: id, name: t["name"] as? String ?? id)
        }
        Keychain.save(password, for: email)
        if self.email != email, !self.email.isEmpty { Keychain.delete(self.email) }
        self.email = email
        UserDefaults.standard.set(email, forKey: "appleID")
        teams = found
        UserDefaults.standard.set(try? JSONEncoder().encode(found), forKey: "teams")
        if !found.contains(where: { $0.id == selectedTeam }) { selectedTeam = found.first?.id ?? "" }
        showSignIn = false
        checkAccount()
    }

    func signOut() {
        Keychain.delete(email)
        email = ""; teams = []; selectedTeam = ""
        for k in ["appleID", "teams", "team"] { UserDefaults.standard.removeObject(forKey: k) }
        checkAccount()
    }

    /// A helper event during sign-in or install. Returns true if it was a code request.
    @discardableResult
    func handle(_ ev: [String: Any], _ run: Helper.Run) -> Bool {
        guard ev["need"] as? String == "code" else { return false }
        pending = run
        codePrompt = CodePrompt(sms: ev["sms"] as? Bool ?? false, lastError: ev["lastError"] as? String)
        showSignIn = true
        return true
    }

    func submitCode(_ code: String) {
        pending?.send(["code": code.filter(\.isNumber)])
        codePrompt = nil
        if !signingIn { showSignIn = false }   // mid-install: the install carries on
    }

    func cancelSignIn() {
        pending?.send(["abort": true])
        pending = nil; codePrompt = nil
        showSignIn = false
    }

    // MARK: iPhone

    private func checkPhone() async {
        let r = await Helper.call(["devices"])
        let phones: [Phone] = (r.body["devices"] as? [[String: Any]] ?? []).map {
            Phone(udid: $0["udid"] as? String ?? "", name: $0["name"] as? String ?? "iPhone",
                  paired: $0["paired"] as? Bool ?? false, devMode: $0["devMode"] as? Bool)
        }
        guard let p = phones.first(where: { $0.udid == phone?.udid }) ?? phones.first else {
            phone = nil
            connected = .init(state: .bad, title: "iPhone plugged in",
                              detail: "Plug your iPhone into this Mac with a cable and unlock it.")
            trusted = .waiting("iPhone trusts this Mac", "Waiting for iPhone")
            devMode = .waiting("Developer Mode on", "Waiting for iPhone")
            return
        }
        phone = p
        connected = .init(state: .ok, title: "iPhone plugged in", detail: p.name)
        guard p.paired else {
            trusted = .init(state: .bad, title: "iPhone trusts this Mac",
                            detail: "Unlock your iPhone and tap Trust, then enter your passcode.")
            devMode = .waiting("Developer Mode on", "Waiting for Trust")
            return
        }
        trusted = .init(state: .ok, title: "iPhone trusts this Mac", detail: "Trusted")
        devMode = p.devMode == true
            ? .init(state: .ok, title: "Developer Mode on", detail: "On")
            : .init(state: .bad, title: "Developer Mode on",
                    detail: "On iPhone: Settings › Privacy & Security › Developer Mode › On. It restarts; tap Turn On after.")
    }

    func askTrust() async {
        guard let p = phone else { return }
        busy = "trust"
        _ = await Helper.call(["trust", "--udid", p.udid])
        busy = nil
        await refresh()
    }

    /// Developer Mode stays hidden in Settings until a Mac asks for it.
    func revealDevMode() async {
        guard let p = phone else { return }
        busy = "devmode"
        _ = await Helper.call(["devmode", "--udid", p.udid])
        busy = nil
    }

    // MARK: after install

    private func checkAfterInstall() async {
        guard let p = phone, p.paired, p.devMode == true else {
            appOnPhone = .waiting("GPS Spoofer on iPhone", "Not installed yet")
            vpnOnPhone = .waiting("LocalDevVPN on iPhone", "Waiting for iPhone")
            link = .waiting("Connected", "Waiting for the app")
            return
        }
        // The app list is slow; every third tick is plenty.
        guard Date().timeIntervalSince(lastPhoneScan) > 8 || appOnPhone.state == .waiting else { return }
        lastPhoneScan = Date()

        let r = await Helper.call(["apps", "--udid", p.udid])
        let apps = r.body["apps"] as? [[String: Any]] ?? []
        let ids = apps.compactMap { $0["id"] as? String }
        let names = apps.compactMap { $0["name"] as? String }

        // The installed copy for the selected team, or any GPS Spoofer this Mac put there.
        let bundle = bundleID.flatMap { ids.contains($0) ? $0 : nil }
            ?? ids.first { $0.hasPrefix("ai.toolbay.gpsspoofer.") }
        if let bundle {
            var detail = "Installed"
            let expiry = UserDefaults.standard.object(forKey: "expiry.\(bundle)") as? Date
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

        guard let bundle else { link = .waiting("Connected", "Waiting for the app"); return }
        let st = await Helper.call(["status", "--udid", p.udid, "--bundle", bundle])
        guard st.ok, let s = st.body["status"] as? [String: Any] else {
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
