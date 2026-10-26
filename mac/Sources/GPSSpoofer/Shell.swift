import Foundation
import Security

/// Runs gs-helper (mac/helper, bundled in Contents/MacOS) off the main thread. It does everything that
/// used to need Xcode: talks to the iPhone over USB, signs in to Apple, signs and installs the app.
/// It prints JSON lines: events while it works, then one final {"ok": …} line.
enum Helper {
    struct Result {
        let ok: Bool
        let body: [String: Any]
        var error: String { body["error"] as? String ?? "Something went wrong. Try again." }
        var details: String { body["details"] as? String ?? "" }
        var failure: InstallError { InstallError(error, details) }
    }

    static var path: String {
        if let p = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("gs-helper").path,
           FileManager.default.isExecutableFile(atPath: p) { return p }
        if let dev = ProcessInfo.processInfo.environment["GS_HELPER"] { return dev }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../helper/target/release/gs-helper").standardized.path
    }

    /// A running helper: `send` answers its questions (the 2FA code) on stdin.
    final class Run: @unchecked Sendable {
        fileprivate let input = Pipe()
        func send(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// `input` goes in as the first stdin line (the Apple ID). `onEvent` gets every non-final line on
    /// the main actor, with the Run so it can reply.
    static func call(_ args: [String], input: [String: Any]? = nil,
                     onEvent: @escaping @MainActor ([String: Any], Run) -> Void = { _, _ in }) async -> Result {
        let run = Run()
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = run.input
                var errData = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: Result(ok: false, body: ["error": "GPS Spoofer is missing a part. Reinstall it.",
                                                                    "details": "\(path): \(error.localizedDescription)"]))
                    return
                }
                if let input { run.send(input) }

                var final: [String: Any]?
                var buffer = Data()
                let reader = out.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    buffer += chunk
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer = Data(buffer[buffer.index(after: nl)...])
                        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        if obj["ok"] != nil { final = obj } else { DispatchQueue.main.async { onEvent(obj, run) } }
                    }
                }
                p.waitUntilExit()
                g.wait()
                try? run.input.fileHandleForWriting.close()
                if let final {
                    cont.resume(returning: Result(ok: final["ok"] as? Bool ?? false, body: final))
                } else {
                    let tail = String(decoding: errData, as: UTF8.self).split(separator: "\n").suffix(12).joined(separator: "\n")
                    cont.resume(returning: Result(ok: false, body: ["error": "Something went wrong. Try again.",
                                                                    "details": "exit \(p.terminationStatus)\n\(tail)"]))
                }
            }
        }
    }
}

/// The Apple ID password lives in the login keychain, never on disk.
enum Keychain {
    private static let service = "GPS Spoofer Apple ID"

    static func password(for email: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: email, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String, for email: String) {
        delete(email)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: email, kSecValueData as String: Data(password.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ email: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: email]
        SecItemDelete(q as CFDictionary)
    }
}
