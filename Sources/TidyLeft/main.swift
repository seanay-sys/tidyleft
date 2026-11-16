import AppKit
import SwiftUI

struct TidyLeftApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("TidyLeft") {
            RootView()
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `TidyLeft --report [--containers]` prints a dry-run report without opening a window.
if CommandLine.arguments.contains("--report") {
    let scanner = LeftoverScanner(includeContainers: CommandLine.arguments.contains("--containers"))
    let result = scanner.scan { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
    print("Installed apps indexed: \(result.appCount)")
    for g in result.groups {
        print("\n[\(g.confidence.label)] \(g.displayName) — \(Format.bytes(g.totalSize))")
        for i in g.items {
            print("    \(i.requiresAdmin ? "🔒" : "  ")\(i.category.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Format.path(i.url))  (\(Format.bytes(i.size)))")
        }
    }
    exit(0)
}

// Debug aid: `--print-remove-script TRASH_DIR PATH…` prints the script that would run as root.
if let i = CommandLine.arguments.firstIndex(of: "--print-remove-script") {
    let args = Array(CommandLine.arguments.dropFirst(i + 1))
    print(PrivilegedRemover.shellScript(for: args.dropFirst().map { URL(fileURLWithPath: $0) },
                                        trash: URL(fileURLWithPath: args[0])))
    exit(0)
}

// Debug aid: `--check-safety PATH…` prints whether each path could ever be removed.
if let i = CommandLine.arguments.firstIndex(of: "--check-safety") {
    for path in CommandLine.arguments.dropFirst(i + 1) {
        print(SafetyPolicy.canRemove(URL(fileURLWithPath: path)) ? "removable " : "PROTECTED ", path)
    }
    exit(0)
}

// Debug aid: `--check-fda` reports whether protected files can be read.
if CommandLine.arguments.contains("--check-fda") {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for p in [home + "/Library/Safari", home + "/Library/Mail", home + "/Library/Messages",
              home + "/Library/Containers/com.apple.stocks", "/Library/Application Support/com.apple.TCC"] {
        if let d = opendir(p) { closedir(d); print("readable ", p) } else { print("blocked(\(errno))", p) }
    }
    print("checkFullDiskAccess =", AppState.checkFullDiskAccess())
    exit(0)
}

// Debug aids for the other sections (dry runs; nothing is moved).
if CommandLine.arguments.contains("--list-apps") {
    for app in AppCatalog.installedApps() { print(app.name, "|", app.bundleID, app.isAppStore ? "| App Store" : "") }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--related") {
    let apps = AppCatalog.installedApps()
    let target = CommandLine.arguments[i + 1]
    guard let app = apps.first(where: { $0.url.path == target || $0.name == target }) else { print("Not an uninstallable app:", target); exit(1) }
    let others = Set(apps.filter { $0.url != app.url }.map { $0.bundleID.lowercased() })
    for f in AppCatalog.relatedFiles(for: app, otherAppIDs: others) {
        print(f.confidence == .high ? "[x]" : "[ ]", f.requiresAdmin ? "🔒" : "  ", f.category.padding(toLength: 20, withPad: " ", startingAt: 0),
              Format.path(f.url), "(\(Format.bytes(f.size)))", "—", f.reason)
    }
    exit(0)
}
if CommandLine.arguments.contains("--dev-junk") {
    let home = FileManager.default.homeDirectoryForCurrentUser
    for e in DevJunkCatalog.entries {
        for p in e.paths where FileManager.default.fileExists(atPath: home.appendingPathComponent(p).path) {
            let url = home.appendingPathComponent(p)
            print(SafetyPolicy.canRemoveDevJunk(url) ? "ok " : "NO ", e.title, "|", Format.path(url), "|", Format.bytes(LeftoverScanner.size(of: url)))
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--broken-settings") {
    let found = BrokenSettingsScanner.scan()
    print("\(found.count) broken")
    for b in found { print(b.appName ?? b.bundleID, "|", b.problem, "|", Format.path(b.url)) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--disk-usage") {
    let root = URL(fileURLWithPath: (CommandLine.arguments[i + 1] as NSString).expandingTildeInPath)
    let index = DiskIndex()
    let total = DiskScanner.scan(root, index: index) { false }
    print(Format.path(root), Format.bytes(total), "\(index.files) files")
    for e in (index.get(root.path) ?? []).prefix(15) {
        print(e.blockReason == nil ? "   " : "🔒 ", Format.bytes(e.size).padding(toLength: 10, withPad: " ", startingAt: 0),
              e.appName.map { "\($0) (\(e.name))" } ?? e.name, e.blockReason.map { "— \($0)" } ?? "")
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--check-paths") {
    for path in CommandLine.arguments.dropFirst(i + 1) {
        let url = URL(fileURLWithPath: path)
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        print("uninstall:", SafetyPolicy.canUninstall(url), "| devjunk:", SafetyPolicy.canRemoveDevJunk(url),
              "| diskusage:", SafetyPolicy.diskUsageBlockReason(url, isDirectory: isDir) ?? "removable", "|", path)
    }
    exit(0)
}

TidyLeftApp.main()
