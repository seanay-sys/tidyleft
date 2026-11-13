import AppKit
import SwiftUI

@MainActor
final class CleanerModel: ObservableObject {
    @Published var groups: [LeftoverGroup] = []
    @Published var selected: Set<URL> = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var status = "Scan to find files left behind by apps you've removed."
    @Published var includeContainers = false
    @Published var includeSystem = true
    @Published var minConfidence: Confidence = .medium
    @Published var search = ""
    @Published var message: String?
    @Published var confirmTrash = false
    @Published var hasFullDiskAccess = CleanerModel.checkFullDiskAccess()

    private var activeObserver: NSObjectProtocol?

    init() {
        // Re-check whenever the user comes back from System Settings.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasFullDiskAccess = CleanerModel.checkFullDiskAccess() }
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

    var visibleGroups: [LeftoverGroup] {
        let q = search.lowercased()
        return groups.compactMap { g in
            var g = g
            g.items = g.items.filter { $0.confidence >= minConfidence }
            guard !g.items.isEmpty else { return nil }
            if !q.isEmpty, !g.displayName.lowercased().contains(q),
               !g.items.contains(where: { $0.url.path.lowercased().contains(q) }) { return nil }
            return g
        }
    }

    var visibleItems: [LeftoverItem] { visibleGroups.flatMap(\.items) }

    /// Only what's currently shown counts; hidden (filtered-out) items are never removed.
    var selectedItems: [LeftoverItem] { visibleItems.filter { selected.contains($0.url) } }

    var selectedAdminCount: Int { selectedItems.filter(\.requiresAdmin).count }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var allVisibleSelected: Bool {
        let items = visibleItems
        return !items.isEmpty && items.allSatisfy { selected.contains($0.url) }
    }

    func selectAllVisible(_ on: Bool) {
        for item in visibleItems {
            if on { selected.insert(item.url) } else { selected.remove(item.url) }
        }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        selected = []
        let running = NSWorkspace.shared.runningApplications
        let scanner = LeftoverScanner(
            includeContainers: includeContainers,
            includeSystem: includeSystem,
            runningBundleIDs: running.compactMap(\.bundleIdentifier),
            runningNames: running.compactMap(\.localizedName))

        Task.detached(priority: .userInitiated) {
            let result = scanner.scan { [weak self] msg in
                Task { @MainActor in self?.status = msg }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.groups = result.groups
                // Only pre-select the items we're most confident about.
                self.selected = Set(result.groups.flatMap(\.items).filter { $0.confidence == .high }.map(\.url))
                let total = result.groups.reduce(0) { $0 + $1.totalSize }
                self.status = "\(result.groups.count) leftovers found (\(Format.bytes(total))) · checked against \(result.appCount) apps"
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    func isGroupSelected(_ g: LeftoverGroup) -> Bool {
        !g.items.isEmpty && g.items.allSatisfy { selected.contains($0.url) }
    }

    func setGroup(_ g: LeftoverGroup, selected on: Bool) {
        for item in g.items {
            if on { selected.insert(item.url) } else { selected.remove(item.url) }
        }
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Moves the selected items to the Trash (recoverable), never deletes outright.
    func trashSelected() {
        // Re-check every item against the safety rules at the last moment.
        let chosen = selectedItems.filter { SafetyPolicy.canRemove($0.url) }
        let userURLs = chosen.filter { !$0.requiresAdmin }.map(\.url)
        let adminURLs = chosen.filter(\.requiresAdmin).map(\.url)
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        Task.detached {
            var trashed = Set<URL>()
            var failures: [String] = []
            for url in userURLs {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashed.insert(url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // System items: one administrator prompt for all of them.
            let admin = PrivilegedRemover.moveToTrash(adminURLs)
            trashed.formUnion(admin.moved)
            if admin.cancelled {
                failures.append("\(adminURLs.count) system item\(adminURLs.count == 1 ? "" : "s") skipped — administrator access was cancelled")
            }
            failures += admin.failed.map { "\($0.0.lastPathComponent): \($0.1)" }
            let freed = trashed.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }

            await MainActor.run { [weak self, trashed, failures] in
                guard let self else { return }
                self.selected.subtract(trashed)
                self.groups = self.groups.compactMap { g in
                    var g = g
                    g.items.removeAll { trashed.contains($0.url) }
                    return g.items.isEmpty ? nil : g
                }
                var text = "Moved \(trashed.count) item\(trashed.count == 1 ? "" : "s") to the Trash (about \(Format.bytes(freed)))."
                if !failures.isEmpty {
                    text += "\n\nNot moved — Full Disk Access often fixes this:\n"
                    text += failures.prefix(8).joined(separator: "\n")
                }
                self.message = text
            }
        }
    }
}
