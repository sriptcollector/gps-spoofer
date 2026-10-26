import Foundation

/// Runs command-line tools off the main thread. Every Xcode tool gets DEVELOPER_DIR pointed at the
/// Xcode we found, so it works even when `xcode-select` still points at the Command Line Tools.
enum Shell {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
        /// Last meaningful line, for the "Details" disclosure. Never shown as the main message.
        var tail: String {
            let all = (err.isEmpty ? out : err).split(separator: "\n").map(String.init)
            return all.suffix(12).joined(separator: "\n")
        }
    }

    static var developerDir: String?

    static func run(_ exe: String, _ args: [String], cwd: String? = nil) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                var env = ProcessInfo.processInfo.environment
                if let d = developerDir { env["DEVELOPER_DIR"] = d }
                p.environment = env
                let o = Pipe(), e = Pipe()
                p.standardOutput = o; p.standardError = e
                // Drain both pipes concurrently so a chatty xcodebuild can't fill one and stall.
                var outData = Data(), errData = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: Result(code: -1, out: "", err: "\(exe): \(error.localizedDescription)"))
                    return
                }
                p.waitUntilExit()
                g.wait()
                cont.resume(returning: Result(code: p.terminationStatus,
                                              out: String(decoding: outData, as: UTF8.self),
                                              err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func xcrun(_ args: [String]) async -> Result { await run("/usr/bin/xcrun", args) }

    /// `xcrun devicectl … --json-output` → the parsed `result` object.
    static func devicectl(_ args: [String]) async -> (Result, [String: Any]?) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await xcrun(["devicectl"] + args + ["--quiet", "--json-output", tmp.path])
        guard let data = try? Data(contentsOf: tmp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (r, nil) }
        return (r, obj["result"] as? [String: Any])
    }

    /// Runs a shell line with an administrator password prompt (macOS's own dialog).
    static func asAdmin(_ line: String) async -> Result {
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
