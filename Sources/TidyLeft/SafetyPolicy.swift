import Darwin
import Foundation
import Security

/// Hard rules that keep macOS itself out of reach. Checked when scanning, and
/// again right before anything is moved, so only third-party leftovers can be removed.
enum SafetyPolicy {
    /// Only direct children of these folders may ever be removed.
    static let allowedParents: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let all = LeftoverScanner(includeContainers: true, includeSystem: true).locations
        return Set(all.map { loc in
            (loc.system ? URL(fileURLWithPath: loc.path) : home.appendingPathComponent(loc.path))
                .standardizedFileURL.path
        })
    }()

    /// Locations macOS owns. A launch service pointing into these is part of the OS.
    static let systemPathPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/Apple/",
                                     "/Library/Developer/CommandLineTools/", "/Applications/Utilities/"]

    /// Identifiers macOS and its bundled open-source components use.
    private static let appleIdentifierPrefixes = [
        "com.apple", "apple", "is.workflow", "tvappservices", "com.icloud", "org.swift.", "org.cups.",
        "org.openldap", "org.ntp", "edu.mit.", "org.postfix", "com.openssh", "org.openssh",
    ]

    static func canRemove(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard allowedParents.contains(url.deletingLastPathComponent().path) else { return false }
        if systemPathPrefixes.contains(where: { url.path.hasPrefix($0) }) { return false }
        if isAppleIdentifier(url.lastPathComponent) { return false }
        // Outside Application Support, the name must identify a third-party bundle
        // (com.vendor.app, TEAMID.something); anonymous names like UUIDs are left alone.
        if url.deletingLastPathComponent().lastPathComponent != "Application Support" {
            var name = url.lastPathComponent
            for s in [".plist", ".savedState", ".binarycookies", ".log"] where name.hasSuffix(s) {
                name = String(name.dropLast(s.count))
            }
            let groupStripped = name.hasPrefix("group.") ? String(name.dropFirst(6)) : name
            guard InstalledAppIndex.isReverseDNS(groupStripped) || InstalledAppIndex.teamPrefix(name) != nil
            else { return false }
        }
        if hasProtectedFlags(url.path) { return false }
        if let bundleID = Bundle(url: url)?.bundleIdentifier, isAppleIdentifier(bundleID) { return false }
        if isCode(url), isAppleSigned(url) { return false }
        return true
    }

    /// True for com.apple.*, group.com.apple.*, TEAMID.com.apple.*, Shortcuts' legacy IDs, etc.
    static func isAppleIdentifier(_ raw: String) -> Bool {
        var s = raw.lowercased()
        if s.hasPrefix(".") || s == "loginwindow" || s == "pbs" { return true }   // .GlobalPreferences etc.
        if let team = InstalledAppIndex.teamPrefix(raw) { s = String(s.dropFirst(team.count + 1)) }
        for p in ["group.", "groups.", "systemgroup."] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if raw.lowercased().hasPrefix("systemgroup.") { return true }
        // Catch any other wrapping, e.g. "243LU875E5.groups.com.apple.podcasts".
        if s.contains("com.apple") || s.contains("apple.") { return true }
        return appleIdentifierPrefixes.contains { s.hasPrefix($0) }
    }

    /// SIP-restricted, immutable, or no-unlink files belong to the system.
    static func hasProtectedFlags(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }   // can't inspect → don't touch
        let restricted: UInt32 = 0x0008_0000, sfImmutable: UInt32 = 0x0002_0000
        let ufImmutable: UInt32 = 0x0000_0002, noUnlink: UInt32 = 0x0010_0000
        return st.st_flags & (restricted | sfImmutable | ufImmutable | noUnlink) != 0
    }

    /// Signed by Apple itself (not just a Developer ID certificate issued by Apple).
    static func isAppleSigned(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), req) == errSecSuccess
    }

    private static func isCode(_ url: URL) -> Bool {
        if ["app", "bundle", "framework", "plugin", "appex", "xpc", "kext", "dylib"].contains(url.pathExtension) {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
