import AppKit
import SwiftUI

struct LeftoverCleanerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("Leftover Cleaner") {
            ContentView()
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

// `LeftoverCleaner --report [--containers]` prints a dry-run report without opening a window.
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

LeftoverCleanerApp.main()
