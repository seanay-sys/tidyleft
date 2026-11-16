import AppKit
import SwiftUI

/// A third-party preference file that its app can't use: damaged, empty, or owned by
/// another user (often root, after running an app with sudo), so settings never save.
struct BrokenSetting: Identifiable, Hashable, Sendable {
    let url: URL
    let bundleID: String
    let appName: String?
    let problem: String
    let fix: String
    let requiresAdmin: Bool
    var size: Int64

    var id: URL { url }
}

enum BrokenSettingsScanner {
    static func scan() -> [BrokenSetting] {
        let fm = FileManager.default
        let dirs: [(URL, Bool)] = [(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences"), false),
                                   (URL(fileURLWithPath: "/Library/Preferences"), true)]
        let uid = getuid()
        var out: [BrokenSetting] = []
        for (dir, system) in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for url in files where url.pathExtension == "plist" {
                let id = url.deletingPathExtension().lastPathComponent
                // Third-party only, and only files the safety rules would ever let us move.
                guard !SafetyPolicy.isAppleIdentifier(id), SafetyPolicy.canRemove(url) else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }

                var problem: String?
                var fix = "The app creates a fresh settings file the next time it opens. Its settings go back to their defaults."
                if !system, st.st_uid != uid {
                    problem = "Owned by another user (\(userName(st.st_uid))), so the app can't save its settings"
                    fix = "Removing it lets the app save settings again. " + fix
                } else if st.st_size == 0 {
                    problem = "Empty file"
                } else if let data = fm.contents(atPath: url.path) {
                    if (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                        problem = "Damaged — the file can't be read"
                    }
                } else if !system {
                    problem = "Can't be opened, so the app can't read its settings"
                }
                guard let problem else { continue }
                out.append(BrokenSetting(url: url, bundleID: id, appName: AppName.forBundleID(id), problem: problem,
                                         fix: fix, requiresAdmin: system, size: Int64(st.st_size)))
            }
        }
        return out.sorted { ($0.appName ?? $0.bundleID).localizedCaseInsensitiveCompare($1.appName ?? $1.bundleID) == .orderedAscending }
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return "uid \(uid)" }
        return String(cString: name)
    }
}

@MainActor
final class BrokenSettingsModel: ObservableObject {
    @Published var items: [BrokenSetting] = []
    @Published var selected: Set<URL> = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var status = "Finds app settings files that are damaged or can't be saved, which can make apps crash or forget settings."
    @Published var confirm = false
    @Published var message: String?

    var selectedItems: [BrokenSetting] { items.filter { selected.contains($0.url) } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        status = "Checking settings files…"
        Task.detached(priority: .userInitiated) {
            let found = BrokenSettingsScanner.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = found
                self.selected = Set(found.map(\.url))
                self.status = found.isEmpty ? "All third-party settings files are healthy."
                    : "\(found.count) settings file\(found.count == 1 ? "" : "s") with problems"
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    func trashSelected() {
        let chosen = selectedItems.filter { SafetyPolicy.canRemove($0.url) }
        Task.detached {
            // Quit the owning apps so they don't write the old settings straight back.
            for item in chosen {
                NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).forEach { $0.terminate() }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let out = Trasher.moveToTrash(chosen.map(\.url), allowAdmin: true)
            // Make the preferences daemon forget its cached copy.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["-u", NSUserName(), "cfprefsd"]
            try? p.run()
            p.waitUntilExit()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items.removeAll { out.moved.contains($0.url) }
                self.selected.subtract(out.moved)
                var text = "Moved \(out.moved.count) settings file\(out.moved.count == 1 ? "" : "s") to the Trash. The apps will start with fresh settings."
                if !out.failures.isEmpty { text += "\n\nNot moved:\n" + out.failures.prefix(8).joined(separator: "\n") }
                self.message = text
            }
        }
    }
}

struct BrokenSettingsView: View {
    @ObservedObject var model: BrokenSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "wrench.and.screwdriver", title: "Broken Settings", status: model.status) {
                ScanButton(hasScanned: model.hasScanned, isScanning: model.isScanning) { model.scan() }
            }
            Divider()
            if model.items.isEmpty {
                EmptyStateView(
                    icon: model.hasScanned ? "checkmark.seal" : "wrench.and.screwdriver",
                    title: model.hasScanned ? "No broken settings" : "Check app settings files",
                    message: model.hasScanned
                        ? "Every third-party settings file can be read and saved."
                        : "An app whose settings file is damaged, empty or owned by another user can crash at launch or forget your changes. Removing the file lets the app start fresh. macOS's own settings are never checked or touched.",
                    buttonTitle: model.hasScanned || model.isScanning ? nil : "Check Now",
                    action: { model.scan() })
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack(spacing: 10) {
                            CheckBox(isOn: model.selected.contains(item.url)) { _ in model.toggle(item.url) }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.appName ?? item.bundleID).font(.body.weight(.medium))
                                    if item.requiresAdmin { Image(systemName: "lock.fill").font(.caption2) }
                                }
                                Text(item.problem).font(.callout).foregroundStyle(.orange)
                                Text(item.fix).font(.caption).foregroundStyle(.secondary)
                                Text(Format.path(item.url)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            RevealButton(url: item.url)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            TrashFooter(count: model.selectedItems.count, size: model.selectedItems.reduce(0) { $0 + $1.size },
                        buttonTitle: "Reset Settings",
                        disabled: model.selectedItems.isEmpty || model.isScanning,
                        action: { model.confirm = true }) { EmptyView() }
        }
        .confirmationDialog("Reset \(model.selectedItems.count) app\(model.selectedItems.count == 1 ? "" : "s") to default settings?",
                            isPresented: $model.confirm, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { model.trashSelected() }
        } message: {
            Text("The apps are quit first and their settings files go to the Trash, so you can put them back.")
        }
        .resultAlert($model.message)
    }
}
