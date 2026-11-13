import Foundation
import Security

/// Everything we know about what is currently installed, used to decide whether
/// a file in ~/Library still has an owner.
struct InstalledAppIndex: Sendable {
    private(set) var bundleIDs = Set<String>()   // lowercased
    private(set) var vendors = Set<String>()     // e.g. "com.google"
    private(set) var names = Set<String>()       // normalized app / tool names
    private(set) var teamIDs = Set<String>()     // lowercased code-signing team IDs
    private(set) var appGroups = Set<String>()   // lowercased app-group entitlements
    private(set) var appCount = 0

    enum Ownership: Equatable {
        case installed
        case sameVendor(String)
        case unknownTeam
        case unknown
    }

    // MARK: Building

    static func build(runningBundleIDs: [String], runningNames: [String]) -> InstalledAppIndex {
        var idx = InstalledAppIndex()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var seen = Set<String>()

        let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices",
                     "/Library/Application Support", home + "/Applications"]
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if url.pathExtension == "app" {
                    if seen.insert(url.path).inserted {
                        idx.add(appAt: url, deep: !url.path.hasPrefix("/System/"))
                    }
                } else if e.level >= 4 {
                    e.skipDescendants()
                }
            }
        }

        // Apps installed elsewhere (Downloads, external drives, Xcode bundles…).
        for path in spotlightApps() where seen.insert(path).inserted {
            idx.add(appAt: URL(fileURLWithPath: path), deep: false)
        }

        runningBundleIDs.forEach { idx.addID($0) }
        runningNames.forEach { idx.names.insert(normalize($0)) }
        idx.addCommandLineTools()
        if let own = Bundle.main.bundleIdentifier { idx.addID(own) }
        idx.names.remove("")
        return idx
    }

    private mutating func add(appAt url: URL, deep: Bool) {
        guard let bundle = Bundle(url: url) else { return }
        appCount += 1
        addBundleInfo(bundle, fileName: url.deletingPathExtension().lastPathComponent)
        guard deep else { return }

        // Helpers, login items, extensions and frameworks often use their own identifiers.
        let nested = ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/PlugIns",
                      "Contents/XPCServices", "Contents/Helpers", "Contents/Library/SystemExtensions",
                      "Contents/Frameworks"]
        for sub in nested {
            let dir = url.appendingPathComponent(sub)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where ["app", "appex", "xpc", "framework", "systemextension", "bundle"].contains(item.pathExtension) {
                if let b = Bundle(url: item) { addBundleInfo(b, fileName: nil) }
            }
        }
        addSigningInfo(url)
    }

    private mutating func addBundleInfo(_ bundle: Bundle, fileName: String?) {
        if let fileName { names.insert(Self.normalize(fileName)) }
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let n = bundle.object(forInfoDictionaryKey: key) as? String { names.insert(Self.normalize(n)) }
        }
        if let id = bundle.bundleIdentifier { addID(id) }
    }

    private mutating func addSigningInfo(_ url: URL) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
            teamIDs.insert(team.lowercased())
        }
        if let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
           let groups = ent["com.apple.security.application-groups"] as? [String] {
            groups.forEach { appGroups.insert($0.lowercased()) }
        }
    }

    mutating func addID(_ raw: String) {
        let id = raw.lowercased()
        bundleIDs.insert(id)
        if let v = Self.vendor(of: id) { vendors.insert(v) }
    }

    /// CLI tools and Homebrew packages keep folders in ~/Library too; don't flag those.
    private mutating func addCommandLineTools() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/Caskroom", "/usr/local/Caskroom",
                    "/opt/homebrew/Cellar", "/usr/local/Cellar", home + "/.local/bin", home + "/.cargo/bin"]
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                names.insert(Self.normalize(name))
            }
        }
    }

    private static func spotlightApps() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") }
    }

    // MARK: Matching

    func ownership(of rawIdentifier: String) -> Ownership {
        var id = rawIdentifier.lowercased()
        if appGroups.contains(id) { return .installed }

        // "UBF8T346G9.Office" style: app-group container prefixed with a team ID.
        if let team = Self.teamPrefix(rawIdentifier) {
            if teamIDs.contains(team.lowercased()) { return .installed }
            id = String(id.dropFirst(team.count + 1))
            if !Self.isReverseDNS(id) { return .unknownTeam }
        }
        if id.hasPrefix("group.") {
            id = String(id.dropFirst("group.".count))
        }
        for b in bundleIDs where id == b || id.hasPrefix(b + ".") || b.hasPrefix(id + ".") {
            return .installed
        }
        if appGroups.contains(where: { $0.hasSuffix(id) }) { return .installed }
        if let v = Self.vendor(of: id), vendors.contains(v) { return .sameVendor(v) }
        return .unknown
    }

    func matchesName(_ raw: String) -> Bool {
        let n = Self.normalize(raw)
        if n.count < 3 || names.contains(n) { return true }
        for token in names where token.count >= 5 {
            if n.contains(token) || (n.count >= 5 && token.contains(n)) { return true }
        }
        return false
    }

    // MARK: Helpers

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func vendor(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    private static let topLevel: Set<String> = [
        "com", "org", "net", "io", "de", "uk", "co", "us", "ru", "jp", "fr", "dev", "app", "me", "info",
        "ch", "nl", "se", "it", "cc", "at", "be", "ca", "au", "tv", "ai", "cn", "edu", "gov", "eu", "es",
        "pl", "no", "dk", "fi", "br", "in", "kr", "tw", "sh", "so", "is", "im", "ly", "to", "xyz", "pro",
    ]

    static func isReverseDNS(_ id: String) -> Bool {
        let parts = id.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let first = String(parts[0])
        if topLevel.contains(first) { return true }
        return parts.count >= 3 && (2...6).contains(first.count) && first.allSatisfy(\.isLetter)
    }

    /// Returns the 10-character team ID prefix (e.g. "UBF8T346G9") if present.
    static func teamPrefix(_ raw: String) -> String? {
        guard let dot = raw.firstIndex(of: ".") else { return nil }
        let head = raw[..<dot]
        guard head.count == 10,
              head.allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }),
              head.contains(where: \.isNumber) else { return nil }
        return String(head)
    }
}
