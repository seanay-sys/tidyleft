import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case leftovers, uninstall, devJunk, diskUsage, brokenSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftovers: "Leftovers"
        case .uninstall: "Uninstall Apps"
        case .devJunk: "Developer Junk"
        case .diskUsage: "Disk Usage"
        case .brokenSettings: "Broken Settings"
        }
    }

    var icon: String {
        switch self {
        case .leftovers: "sparkles"
        case .uninstall: "xmark.app"
        case .devJunk: "hammer"
        case .diskUsage: "chart.bar.doc.horizontal"
        case .brokenSettings: "wrench.and.screwdriver"
        }
    }

    var subtitle: String {
        switch self {
        case .leftovers: "Files from deleted apps"
        case .uninstall: "Remove apps completely"
        case .devJunk: "Build files & package caches"
        case .diskUsage: "What's using space"
        case .brokenSettings: "Damaged preference files"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var section: AppSection? = .leftovers
    @Published var hasFullDiskAccess = AppState.checkFullDiskAccess()

    private var activeObserver: NSObjectProtocol?

    init() {
        // Re-check whenever the user comes back from System Settings.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasFullDiskAccess = AppState.checkFullDiskAccess() }
        }
    }

    /// Folders macOS hides from apps without Full Disk Access. If any of them can be
    /// listed, access is granted; missing folders are skipped (not every Mac has them).
    nonisolated static func checkFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [home + "/Library/Safari", home + "/Library/Mail", home + "/Library/Messages",
                      home + "/Library/Containers/com.apple.stocks", "/Library/Application Support/com.apple.TCC"]
        for path in probes {
            guard let dir = opendir(path) else { continue }   // EPERM (blocked) or ENOENT (missing)
            closedir(dir)
            return true
        }
        return false
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct RootView: View {
    @StateObject private var app = AppState()
    @StateObject private var leftovers = CleanerModel()
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var devJunk = DevJunkModel()
    @StateObject private var diskUsage = DiskUsageModel()
    @StateObject private var broken = BrokenSettingsModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $app.section) {
                ForEach(AppSection.allCases) { s in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                            Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: s.icon)
                    }
                    .padding(.vertical, 3)
                    .tag(s)
                }
            }
            .safeAreaInset(edge: .bottom) { accessStatus }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch app.section ?? .leftovers {
            case .leftovers: LeftoversView(model: leftovers)
            case .uninstall: UninstallerView(model: uninstaller)
            case .devJunk: DevJunkView(model: devJunk)
            case .diskUsage: DiskUsageView(model: diskUsage)
            case .brokenSettings: BrokenSettingsView(model: broken)
            }
        }
        .frame(minWidth: 1040, minHeight: 620)
    }

    private var accessStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if app.hasFullDiskAccess {
                Label("Full Disk Access granted", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button { app.openFullDiskAccessSettings() } label: {
                    Label("Grant Full Disk Access…", systemImage: "lock.shield")
                }
                .buttonStyle(.link).font(.caption)
                .help("Lets TidyLeft see and clean protected folders without repeated prompts.")
            }
            Label("macOS files are never touched", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}
