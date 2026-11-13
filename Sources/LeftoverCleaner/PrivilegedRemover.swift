import Foundation

/// Moves root-owned items (under /Library) to the user's Trash with a single
/// macOS administrator prompt. Launch agents/daemons are unloaded first so the
/// background process stops before its files go away.
enum PrivilegedRemover {
    struct Outcome {
        var moved: [URL] = []
        var failed: [(URL, String)] = []
        var cancelled = false
    }

    static func moveToTrash(_ urls: [URL]) -> Outcome {
        guard !urls.isEmpty else { return Outcome() }
        let fm = FileManager.default
        let shell = shellScript(for: urls, trash: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        let apple = "do shell script \"\(escapeForAppleScript(shell))\" with prompt "
            + "\"Leftover Cleaner wants to move system files left by uninstalled apps to the Trash.\" "
            + "with administrator privileges"
        return run(apple, urls: urls)
    }

    /// The /bin/sh script run as root. Separate so it can be checked without a password prompt.
    static func shellScript(for urls: [URL], trash: URL) -> String {
        let fm = FileManager.default
        let uid = getuid()
        let stamp = Int(Date().timeIntervalSince1970)

        // Unload services before removing the helper binaries they run.
        let ordered = urls.sorted { rank($0) < rank($1) }
        var usedNames = Set<String>()
        var lines: [String] = []
        for url in ordered {
            var name = url.lastPathComponent
            if fm.fileExists(atPath: trash.appendingPathComponent(name).path) || usedNames.contains(name) {
                name += " \(stamp)"
            }
            usedNames.insert(name)
            let src = quote(url.path)
            let dst = quote(trash.appendingPathComponent(name).path)
            var cmd = ""
            if url.path.hasPrefix("/Library/LaunchDaemons/") {
                cmd += "/bin/launchctl bootout system \(src) 2>/dev/null; "
            } else if url.path.hasPrefix("/Library/LaunchAgents/") {
                cmd += "/bin/launchctl bootout gui/\(uid) \(src) 2>/dev/null; "
            }
            cmd += "if /bin/mv \(src) \(dst); then /usr/sbin/chown -R \(uid) \(dst); else echo FAIL:\(src); fi"
            lines.append(cmd)
        }

        return lines.joined(separator: "; ")
    }

    private static func run(_ apple: String, urls: [URL]) -> Outcome {
        let fm = FileManager.default
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var outcome = Outcome()
        do { try p.run() } catch {
            outcome.failed = urls.map { ($0, error.localizedDescription) }
            return outcome
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            if stderr.contains("-128") { outcome.cancelled = true }
            else { outcome.failed = urls.map { ($0, stderr.trimmingCharacters(in: .whitespacesAndNewlines)) } }
            return outcome
        }
        let failedPaths = Set(stdout.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("FAIL:") ? String(line.dropFirst(5)) : nil
        })
        for url in urls {
            if failedPaths.contains(url.path) || fm.fileExists(atPath: url.path) {
                outcome.failed.append((url, "Couldn't be moved (it may be protected by macOS)"))
            } else {
                outcome.moved.append(url)
            }
        }
        return outcome
    }

    private static func rank(_ url: URL) -> Int {
        url.path.contains("/LaunchDaemons/") || url.path.contains("/LaunchAgents/") ? 0 : 1
    }

    /// Single-quotes a path for /bin/sh.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
