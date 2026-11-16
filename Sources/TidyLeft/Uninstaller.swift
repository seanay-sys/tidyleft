import AppKit
import SwiftUI

// MARK: Data

struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let isAppStore: Bool
    var size: Int64 = -1          // -1 while still measuring

    var id: URL { url }
}

struct RelatedFile: Identifiable, Hashable, Sendable {
    let url: URL
    let category: String
    let confidence: Confidence
    let reason: String
    var size: Int64
    let requiresAdmin: Bool

    var id: URL { url }
}

/// Lists third-party apps and finds every file that belongs to one of them.
enum AppCatalog {
    static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [URL] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    found.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    found += sub.filter { $0.pathExtension == "app" }   // e.g. /Applications/Adobe Photoshop/…
                }
            }
        }
        return found.compactMap { url -> InstalledApp? in
            guard SafetyPolicy.canUninstall(url), let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
            let version = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            let mas = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
            return InstalledApp(url: url, name: url.deletingPathExtension().lastPathComponent,
                                bundleID: id, version: version, isAppStore: mas)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The app bundle itself plus its preferences, caches, containers, helpers and launch services.
    static func relatedFiles(for app: InstalledApp, otherAppIDs: Set<String>) -> [RelatedFile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let ownIDs = Set(([app.bundleID] + InstalledAppIndex.helperBundleIDs(app.url)).map { $0.lowercased() })
            .filter { !SafetyPolicy.isAppleIdentifier($0) }
        let groups = Set(InstalledAppIndex.signingInfo(app.url).groups.map { $0.lowercased() })
        var names = Set([InstalledAppIndex.normalize(app.name)])
        if let b = Bundle(url: app.url) {
            for key in ["CFBundleName", "CFBundleExecutable"] {
                if let n = b.object(forInfoDictionaryKey: key) as? String { names.insert(InstalledAppIndex.normalize(n)) }
            }
        }
        names = names.filter { $0.count >= 4 }

        /// True when the identifier belongs to this app and not to another installed app
        /// (so "com.google.Chrome" doesn't claim "com.google.Chrome.canary").
        func ownsID(_ lower: String) -> Bool {
            guard let match = ownIDs.filter({ lower == $0 || lower.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count })
            else { return false }
            return !otherAppIDs.contains { $0.count > match.count && (lower == $0 || lower.hasPrefix($0 + ".")) }
        }

        let appWritable = fm.isWritableFile(atPath: app.url.deletingLastPathComponent().path)
        var out = [RelatedFile(url: app.url, category: "Application", confidence: .high,
                               reason: "The app itself", size: LeftoverScanner.size(of: app.url),
                               requiresAdmin: !appWritable)]
        var seen: Set<URL> = [app.url]

        for loc in LeftoverScanner(includeContainers: true, includeSystem: true).locations {
            let dir = loc.system ? URL(fileURLWithPath: loc.path) : home.appendingPathComponent(loc.path)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for url in entries where !seen.contains(url) {
                var ident = url.lastPathComponent
                for s in [".plist", ".savedState", ".binarycookies", ".log"] where ident.hasSuffix(s) {
                    ident = String(ident.dropLast(s.count))
                }
                let lower = ident.lowercased()
                var confidence: Confidence?
                var reason = ""
                if loc.launchd {
                    let label = LeftoverScanner.launchdLabel(url)?.lowercased() ?? lower
                    let program = LeftoverScanner.launchAgentProgram(url)
                    if ownsID(label) || program?.hasPrefix(app.url.path + "/") == true {
                        confidence = .high
                        reason = "Background service started by \(app.name)"
                    }
                } else if ownsID(lower) {
                    confidence = .high
                    reason = "Uses \(app.name)'s identifier"
                } else if groups.contains(lower) {
                    confidence = .medium
                    reason = "Shared data container — other apps from the same developer may use it"
                } else if ["Application Support", "Caches", "Logs"].contains(loc.category),
                          names.contains(InstalledAppIndex.normalize(ident)) {
                    // Exactly the app's own name (e.g. "Slack") is almost certainly its folder;
                    // matches on internal names are less certain.
                    let exact = InstalledAppIndex.normalize(ident) == InstalledAppIndex.normalize(app.name)
                    confidence = exact && ident.count >= 5 ? .high : .medium
                    reason = "Folder named after \(app.name)"
                }
                guard let confidence, SafetyPolicy.canRemove(url) else { continue }
                seen.insert(url)
                out.append(RelatedFile(url: url, category: loc.category, confidence: confidence, reason: reason,
                                       size: LeftoverScanner.size(of: url), requiresAdmin: loc.system))
            }
        }
        return [out[0]] + out.dropFirst().sorted { $0.size > $1.size }
    }
}

// MARK: Model

@MainActor
final class UninstallerModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable { case name = "Name", size = "Size"; var id: String { rawValue } }

    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var loaded = false
    @Published var search = ""
    @Published var sort: Sort = .name
    @Published var current: URL?
    @Published var related: [RelatedFile] = []
    @Published var isFinding = false
    @Published var checked: Set<URL> = []
    @Published var confirm = false
    @Published var message: String?
    @Published var status = "Pick an app to see everything it installed, then remove it all at once."

    var visibleApps: [InstalledApp] {
        let q = search.lowercased()
        let list = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        return sort == .name ? list : list.sorted { $0.size > $1.size }
    }

    var currentApp: InstalledApp? { apps.first { $0.url == current } }
    var checkedFiles: [RelatedFile] { related.filter { checked.contains($0.url) } }
    var checkedSize: Int64 { checkedFiles.reduce(0) { $0 + $1.size } }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        status = "Finding installed apps…"
        Task.detached(priority: .userInitiated) {
            let found = AppCatalog.installedApps()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apps = found
                self.isLoading = false
                self.loaded = true
                self.status = "\(found.count) third-party apps. Pick one to see everything it installed."
            }
            // Measure sizes in the background; the list fills in as it goes.
            await withTaskGroup(of: (URL, Int64).self) { group in
                for app in found { group.addTask { (app.url, LeftoverScanner.size(of: app.url)) } }
                for await (url, size) in group {
                    await MainActor.run { [weak self] in
                        guard let self, let i = self.apps.firstIndex(where: { $0.url == url }) else { return }
                        self.apps[i].size = size
                    }
                }
            }
        }
    }

    func select(_ url: URL?) {
        current = url
        related = []
        checked = []
        guard let app = currentApp else { return }
        isFinding = true
        let others = Set(apps.filter { $0.url != app.url }.map { $0.bundleID.lowercased() })
        Task.detached(priority: .userInitiated) {
            let files = AppCatalog.relatedFiles(for: app, otherAppIDs: others)
            await MainActor.run { [weak self] in
                guard let self, self.current == app.url else { return }
                self.related = files
                self.checked = Set(files.filter { $0.confidence == .high }.map(\.url))
                self.isFinding = false
            }
        }
    }

    func toggle(_ url: URL) {
        if checked.contains(url) { checked.remove(url) } else { checked.insert(url) }
    }

    func uninstall() {
        guard let app = currentApp else { return }
        // Re-check every path against the safety rules right before moving it.
        let urls = checkedFiles.map(\.url).filter { $0 == app.url ? SafetyPolicy.canUninstall($0) : SafetyPolicy.canRemove($0) }
        let sizes = Dictionary(related.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        isFinding = true
        Task.detached {
            // Quit the app (and its helpers) first so nothing is in use.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            running.forEach { $0.terminate() }
            for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let out = Trasher.moveToTrash(urls, allowAdmin: true)
            let freed = out.moved.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isFinding = false
                self.related.removeAll { out.moved.contains($0.url) }
                self.checked.subtract(out.moved)
                if out.moved.contains(app.url) {
                    self.apps.removeAll { $0.url == app.url }
                    self.current = nil
                    self.related = []
                }
                self.message = "\(app.name): " + Trasher.summary(out, freed: freed)
            }
        }
    }
}

// MARK: View

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "xmark.app", title: "Uninstall Apps", status: model.status) {
                Picker("Sort by", selection: $model.sort) {
                    ForEach(UninstallerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                ScanButton(hasScanned: model.loaded, isScanning: model.isLoading, title: "Refresh") { model.load() }
            }
            Divider()
            HSplitView {
                appList.frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detail.frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .searchable(text: $model.search, prompt: "Search apps")
        .onAppear { if !model.loaded { model.load() } }
        .confirmationDialog(confirmTitle, isPresented: $model.confirm, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("The app will be quit first. Everything goes to the Trash, so you can put it back until you empty it."
                 + (model.checkedFiles.contains(where: \.requiresAdmin) ? " macOS will ask for your administrator password for system-wide items." : ""))
        }
        .resultAlert($model.message)
    }

    private var confirmTitle: String {
        "Uninstall \(model.currentApp?.name ?? "app") and move \(model.checkedFiles.count) item\(model.checkedFiles.count == 1 ? "" : "s") to the Trash?"
    }

    private var appList: some View {
        List(selection: Binding(get: { model.current }, set: { model.select($0) })) {
            ForEach(model.visibleApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text(app.isAppStore ? "App Store · \(app.version)" : app.version)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(app.size < 0 ? "…" : Format.bytes(app.size))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(app.url)
            }
        }
        .overlay {
            if model.isLoading { ProgressView("Finding apps…") }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.currentApp {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3.bold())
                        Text("\(app.bundleID)\(app.version.isEmpty ? "" : " · version \(app.version)")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(model.isFinding ? "Looking for related files…"
                             : "\(model.related.count) items · \(Format.bytes(model.related.reduce(0) { $0 + $1.size })) in total")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                if model.isFinding && model.related.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.related) { file in
                            RelatedRow(file: file, isOn: model.checked.contains(file.url)) { model.toggle(file.url) }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
                Divider()
                TrashFooter(count: model.checkedFiles.count, size: model.checkedSize, buttonTitle: "Uninstall",
                            disabled: model.checkedFiles.isEmpty || model.isFinding,
                            action: { model.confirm = true }) {
                    Text("Green items are pre-selected; orange ones may be shared, so check them first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            EmptyStateView(icon: "xmark.app", title: "Pick an app",
                           message: "TidyLeft shows the app together with its settings, caches, containers, helpers and background services, so you can remove all of it in one go. Apple's own apps are not listed.")
        }
    }
}

private struct RelatedRow: View {
    let file: RelatedFile
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(isOn: isOn) { _ in toggle() }
            HStack(spacing: 4) {
                if file.requiresAdmin { Image(systemName: "lock.fill").font(.caption2) }
                Text(file.category)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .frame(width: 140, alignment: .leading)
            Text(Format.path(file.url))
                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .help(file.reason)
            Spacer()
            if file.category != "Application" {
                ConfidenceBadge(confidence: file.confidence, labels: ("Belongs to app", "Check first"))
            }
            Text(Format.bytes(file.size)).monospacedDigit().font(.callout)
                .frame(width: 80, alignment: .trailing)
            RevealButton(url: file.url)
        }
    }
}
