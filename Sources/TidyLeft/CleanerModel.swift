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

    /// Moves the selected items to the Trash (recoverable), never deletes outright.
    func trashSelected() {
        // Re-check every item against the safety rules at the last moment.
        let chosen = selectedItems.filter { SafetyPolicy.canRemove($0.url) }
        let userURLs = chosen.filter { !$0.requiresAdmin }.map(\.url)
        let adminURLs = chosen.filter(\.requiresAdmin).map(\.url)
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        Task.detached {
            let out = Trasher.moveToTrash(userURLs + adminURLs, allowAdmin: true)
            let trashed = out.moved
            let freed = trashed.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.selected.subtract(trashed)
                self.groups = self.groups.compactMap { g in
                    var g = g
                    g.items.removeAll { trashed.contains($0.url) }
                    return g.items.isEmpty ? nil : g
                }
                self.message = Trasher.summary(out, freed: freed)
            }
        }
    }
}
