import Foundation

/// Walks the per-user Library folders and reports entries that no installed app owns.
struct LeftoverScanner: Sendable {
    var includeContainers: Bool
    var includeSystem: Bool = true
    var runningBundleIDs: [String] = []
    var runningNames: [String] = []

    struct Location: Sendable {
        let category: String
        let path: String           // absolute, or relative to ~ when !system
        var system = false         // under /Library: removing needs an administrator
        var matchNames = false     // also consider non-bundle-ID folder names
        var launchd = false        // launch agent / daemon plists
    }

    var locations: [Location] {
        var l: [Location] = [
            .init(category: "Application Support", path: "Library/Application Support", matchNames: true),
            .init(category: "Caches", path: "Library/Caches"),
            .init(category: "Preferences", path: "Library/Preferences"),
            .init(category: "Saved State", path: "Library/Saved Application State"),
            .init(category: "HTTP Storage", path: "Library/HTTPStorages"),
            .init(category: "WebKit", path: "Library/WebKit"),
            .init(category: "Cookies", path: "Library/Cookies"),
            .init(category: "Logs", path: "Library/Logs"),
            .init(category: "App Scripts", path: "Library/Application Scripts"),
            .init(category: "Launch Agents", path: "Library/LaunchAgents", launchd: true),
        ]
        if includeContainers {
            l.append(.init(category: "Containers", path: "Library/Containers"))
            l.append(.init(category: "Group Containers", path: "Library/Group Containers"))
        }
        if includeSystem {
            l += [
                .init(category: "Application Support", path: "/Library/Application Support", system: true, matchNames: true),
                .init(category: "Caches", path: "/Library/Caches", system: true),
                .init(category: "Preferences", path: "/Library/Preferences", system: true),
                .init(category: "Logs", path: "/Library/Logs", system: true),
                .init(category: "Launch Agents", path: "/Library/LaunchAgents", system: true, launchd: true),
                .init(category: "Launch Daemons", path: "/Library/LaunchDaemons", system: true, launchd: true),
                .init(category: "Helper Tools", path: "/Library/PrivilegedHelperTools", system: true),
            ]
        }
        return l
    }

    func scan(progress: @Sendable (String) -> Void) -> (groups: [LeftoverGroup], appCount: Int) {
        progress("Indexing installed apps…")
        let index = InstalledAppIndex.build(runningBundleIDs: runningBundleIDs, runningNames: runningNames)
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var groups: [String: LeftoverGroup] = [:]

        for loc in locations {
            progress("Scanning \(loc.system ? "/" : "~/")\(loc.category)…")
            let dir = loc.system ? URL(fileURLWithPath: loc.path) : home.appendingPathComponent(loc.path)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for url in entries {
                guard let (key, display, item) = evaluate(url, loc, index) else { continue }
                groups[key, default: LeftoverGroup(id: key, displayName: display, items: [])].items.append(item)
            }
        }

        // Fold folders like "Application Support/CrossOver" into the matching
        // "com.codeweavers.CrossOver" group, so one app's leftovers show up together.
        for (key, nameGroup) in groups where key.hasPrefix("name:") {
            let name = String(key.dropFirst("name:".count))
            guard name.count >= 4,
                  let target = groups.values
                    .filter({ !$0.id.hasPrefix("name:") && $0.confidence >= .medium })
                    .filter({ $0.id.split(separator: ".").dropFirst().contains { InstalledAppIndex.normalize(String($0)).hasPrefix(name) } })
                    .min(by: { ($0.id.count, $0.id) < ($1.id.count, $1.id) })
            else { continue }
            let moved = nameGroup.items.map {
                LeftoverItem(url: $0.url, category: $0.category, confidence: .medium,
                             reason: "Named after \(target.displayName), which looks like a leftover",
                             modified: $0.modified, requiresAdmin: $0.requiresAdmin)
            }
            groups[target.id]?.items.append(contentsOf: moved)
            groups[key] = nil
        }

        // Fold "com.nordvpn.macos.helper" etc. into "com.nordvpn.macos" when both were found.
        for key in groups.keys.sorted(by: { $0.count > $1.count }) where !key.hasPrefix("name:") {
            guard let parent = groups.keys.filter({ !$0.hasPrefix("name:") && key.hasPrefix($0 + ".") })
                    .min(by: { $0.count < $1.count }),
                  let child = groups[key] else { continue }
            groups[parent]?.items += child.items
            groups[key] = nil
        }

        // Folders identified only by a loose name match (not tied to a third-party
        // bundle ID found above) are never offered: they could belong to macOS.
        groups = groups.filter { !$0.key.hasPrefix("name:") }

        var result = Array(groups.values)
        let total = result.reduce(0) { $0 + $1.items.count }
        var done = 0
        for g in result.indices {
            for i in result[g].items.indices {
                done += 1
                if done % 10 == 0 { progress("Measuring sizes… \(done)/\(total)") }
                result[g].items[i].size = Self.size(of: result[g].items[i].url)
            }
            result[g].items.sort { $0.size > $1.size }
        }
        result.sort { ($0.confidence, $0.totalSize) > ($1.confidence, $1.totalSize) }
        return (result, index.appCount)
    }

    // MARK: Evaluation

    private static let suffixes = [".plist", ".savedState", ".binarycookies", ".log"]

    /// Folder names in Application Support that belong to macOS itself.
    private static let systemNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter", "diskimages",
        "fileprovider", "knowledge", "mobilesync", "syncservices", "icloud", "icdd", "dock", "animoji",
        "accounts", "cloudkit", "facetime", "quicklook", "networkserviceproxy", "appstore", "askpermission",
        "familycircle", "dmd", "transparencyd", "videoconference", "ids", "siri", "homeenergyd",
        "locationaccessstored", "contextstoryd", "accessibility", "backgroundtaskmanagement", "steam",
        "audiounits", "plugins", "caches", "mobile documents", "default", "ubiquity", "keychains",
        "ilifemediabrowser", "btserver", "proapps", "livefsd", "intelligenceflow", "categories", "apple",
        "scripteditor", "applepushservice", "networkextension", "dirservices", "sesstorage", "campouiinternal",
        "smartcardservices", "replayd", "scriptingadditions", "corestorage", "coremediaio",
    ]

    private func evaluate(_ url: URL, _ loc: Location, _ index: InstalledAppIndex)
        -> (key: String, display: String, item: LeftoverItem)? {
        let raw = url.lastPathComponent
        if raw == "ByHost" || raw.hasSuffix(".lockfile") || raw.hasPrefix(".") { return nil }

        var ident = raw
        for s in Self.suffixes where ident.hasSuffix(s) { ident = String(ident.dropLast(s.count)) }
        let lower = ident.lowercased()
        // Third-party only: never list anything that belongs to macOS.
        if SafetyPolicy.isAppleIdentifier(ident) || !SafetyPolicy.canRemove(url) { return nil }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var confidence: Confidence
        var reason: String

        if loc.launchd, let program = Self.launchAgentProgram(url) {
            if let label = Self.launchdLabel(url), SafetyPolicy.isAppleIdentifier(label) { return nil }
            if SafetyPolicy.systemPathPrefixes.contains(where: { program.hasPrefix($0) }) { return nil }
            if FileManager.default.fileExists(atPath: program),
               SafetyPolicy.isAppleSigned(URL(fileURLWithPath: program)) { return nil }
            let ownership = index.ownership(of: ident)
            if !FileManager.default.fileExists(atPath: program) {
                confidence = ownership == .installed ? .medium : .high
                reason = "Background service runs a program that no longer exists"
            } else if ownership == .unknown, program.hasPrefix("/Library/"),
                      InstalledAppIndex.isReverseDNS(ident) {
                // Helper still on disk, but the app that installed it is gone.
                confidence = .medium
                reason = "Background service from an app that is no longer installed"
            } else {
                return nil
            }
        } else {
            switch index.ownership(of: ident) {
            case .installed:
                return nil
            case .sameVendor(let vendor):
                confidence = .medium
                reason = "Other \(vendor) apps are installed, but none uses this identifier"
            case .unknownTeam:
                confidence = .medium
                reason = "Shared data from a developer with no installed apps"
            case .unknown:
                if InstalledAppIndex.isReverseDNS(ident) {
                    confidence = .high
                    reason = "No installed app uses this identifier"
                } else if loc.matchNames {
                    if Self.systemNames.contains(lower) || index.matchesName(ident) { return nil }
                    confidence = .low
                    reason = "No installed app has a similar name"
                } else {
                    return nil
                }
            }
        }

        // Third-party SDKs (crash reporters, analytics) share these across many apps.
        let sdkPrefixes = ["com.crashlytics", "com.firebase", "com.google.gmp", "io.fabric", "io.sentry",
                           "com.plausiblelabs", "org.sparkle-project", "com.hockeyapp", "com.segment"]
        if confidence == .high, sdkPrefixes.contains(where: { lower.hasPrefix($0) }) {
            confidence = .medium
            reason = "SDK data that installed apps may share"
        }

        if confidence == .high, let modified, modified > Date().addingTimeInterval(-7 * 86_400) {
            confidence = .medium
            reason += " — but it was modified in the last week"
        }

        let isID = InstalledAppIndex.isReverseDNS(ident) || InstalledAppIndex.teamPrefix(ident) != nil
        let key = isID ? lower : "name:" + InstalledAppIndex.normalize(ident)
        let item = LeftoverItem(url: url, category: loc.category, confidence: confidence,
                                reason: reason, modified: modified, requiresAdmin: loc.system)
        return (key, ident, item)
    }

    private static func launchdLabel(_ url: URL) -> String? {
        (NSDictionary(contentsOf: url) as? [String: Any])?["Label"] as? String
    }

    private static func launchAgentProgram(_ url: URL) -> String? {
        guard let d = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let p = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        guard let p, p.hasPrefix("/") || p.hasPrefix("~") else { return nil }
        return (p as NSString).expandingTildeInPath
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true {
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                               options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            if let fv = try? f.resourceValues(forKeys: keys), fv.isRegularFile == true {
                total += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
