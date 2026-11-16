import AppKit
import SwiftUI

// MARK: Data

struct DUEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let appName: String?          // "Google Chrome" for a cache folder named com.google.Chrome
    var size: Int64
    let isDirectory: Bool
    let modified: Date?
    let blockReason: String?      // why it can't be removed here, or nil

    var id: URL { url }
}

/// Folder listings with sizes, filled in by one scan so drilling down is instant.
final class DiskIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: [DUEntry]] = [:]
    private var fileCount = 0

    func set(_ dir: String, _ entries: [DUEntry]) { lock.lock(); listings[dir] = entries; lock.unlock() }
    func get(_ dir: String) -> [DUEntry]? { lock.lock(); defer { lock.unlock() }; return listings[dir] }
    func addFiles(_ n: Int) { lock.lock(); fileCount += n; lock.unlock() }
    var files: Int { lock.lock(); defer { lock.unlock() }; return fileCount }

    /// After items are trashed: drop them from their folder and shrink every folder above.
    func remove(_ url: URL, size: Int64) {
        lock.lock(); defer { lock.unlock() }
        var child = url
        var first = true
        while true {
            let parent = child.deletingLastPathComponent()
            guard parent.path != child.path, var list = listings[parent.path] else { break }
            if first {
                list.removeAll { $0.url == child }
                first = false
            } else if let i = list.firstIndex(where: { $0.url == child }) {
                list[i].size -= size
            }
            listings[parent.path] = list
            child = parent
        }
    }
}

enum DiskScanner {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .contentModificationDateKey]
    /// Folders deeper than this below the scanned folder are measured but not listed;
    /// opening one scans it on demand.
    static let listDepth = 6

    /// Total size of `dir`, recording its listing (and its subfolders') in `index`.
    static func measure(_ dir: URL, depth: Int, index: DiskIndex, cancelled: @Sendable () -> Bool) -> Int64 {
        if cancelled() { return 0 }
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        else { return 0 }
        let record = depth <= listDepth
        let appNames = record && ["Caches", "Logs"].contains(dir.lastPathComponent)
            && dir.deletingLastPathComponent().lastPathComponent == "Library"
        var total: Int64 = 0
        var files = 0
        var entries: [DUEntry] = []
        for item in items {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let isDir = v.isDirectory == true
            let size: Int64
            if isDir {
                size = measure(item, depth: depth + 1, index: index, cancelled: cancelled)
            } else {
                size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                files += 1
            }
            total += size
            if record {
                let name = item.lastPathComponent
                let app = appNames && InstalledAppIndex.isReverseDNS(name) ? AppName.forBundleID(name) : nil
                entries.append(DUEntry(url: item, name: name, appName: app, size: size, isDirectory: isDir,
                                       modified: v.contentModificationDate,
                                       blockReason: SafetyPolicy.diskUsageBlockReason(item, isDirectory: isDir)))
            }
        }
        index.addFiles(files)
        if record { index.set(dir.path, entries.sorted { $0.size > $1.size }) }
        return total
    }

    /// Scans the folder's children in parallel; returns the folder's total size.
    static func scan(_ root: URL, index: DiskIndex, cancelled: @Sendable () -> Bool) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])
        else { return 0 }
        let lock = NSLock()
        var entries: [DUEntry] = []
        var total: Int64 = 0
        let appNames = ["Caches", "Logs"].contains(root.lastPathComponent)
            && root.deletingLastPathComponent().lastPathComponent == "Library"
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let item = items[i]
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return }
            let isDir = v.isDirectory == true
            let size = isDir ? measure(item, depth: 1, index: index, cancelled: cancelled)
                             : Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if !isDir { index.addFiles(1) }
            let name = item.lastPathComponent
            let app = appNames && InstalledAppIndex.isReverseDNS(name) ? AppName.forBundleID(name) : nil
            let entry = DUEntry(url: item, name: name, appName: app, size: size, isDirectory: isDir,
                                modified: v.contentModificationDate,
                                blockReason: SafetyPolicy.diskUsageBlockReason(item, isDirectory: isDir))
            lock.lock(); entries.append(entry); total += size; lock.unlock()
        }
        index.set(root.path, entries.sorted { $0.size > $1.size })
        return total
    }
}

// MARK: Model

@MainActor
final class DiskUsageModel: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case caches = "App caches", logs = "Logs", home = "Home folder"
        var id: String { rawValue }
        var url: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .caches: return home.appendingPathComponent("Library/Caches")
            case .logs: return home.appendingPathComponent("Library/Logs")
            case .home: return home
            }
        }
    }

    @Published var preset: Preset? = .caches
    @Published var trail: [URL] = []          // breadcrumb: scanned folder … current folder
    @Published var entries: [DUEntry] = []
    @Published var totals: [URL: Int64] = [:]
    @Published var isScanning = false
    @Published var status = "See what's taking up space, biggest first. Start with app caches, or pick any folder."
    @Published var selected: Set<URL> = []
    @Published var search = ""
    @Published var confirm = false
    @Published var message: String?

    private var index = DiskIndex()
    private var scanID = 0

    var current: URL? { trail.last }
    var currentTotal: Int64 { current.flatMap { totals[$0] } ?? entries.reduce(0) { $0 + $1.size } }
    var visibleEntries: [DUEntry] {
        let q = search.lowercased()
        return q.isEmpty ? entries : entries.filter { $0.name.lowercased().contains(q) || ($0.appName?.lowercased().contains(q) ?? false) }
    }
    var selectedEntries: [DUEntry] { entries.filter { selected.contains($0.url) } }
    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    func scan(_ preset: Preset) {
        self.preset = preset
        scan(root: preset.url)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to see what's using space inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preset = nil
        scan(root: url)
    }

    func scan(root: URL) {
        scanID += 1
        let id = scanID
        index = DiskIndex()
        let index = self.index
        trail = [root]
        entries = []
        totals = [:]
        selected = []
        isScanning = true
        status = "Measuring \(Format.path(root))…"
        let start = Date()
        // Progress ticker.
        Task { [weak self] in
            while let self, self.isScanning, self.scanID == id {
                self.status = "Measuring \(Format.path(root))… \(index.files.formatted()) files"
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        Task.detached(priority: .userInitiated) {
            let total = DiskScanner.scan(root, index: index) { false }
            await MainActor.run { [weak self] in
                guard let self, self.scanID == id else { return }
                self.isScanning = false
                self.totals[root] = total
                self.entries = index.get(root.path) ?? []
                let secs = Date().timeIntervalSince(start)
                self.status = "\(Format.path(root)) uses \(Format.bytes(total)) · \(index.files.formatted()) files · scanned in \(String(format: "%.1f", secs)) s"
            }
        }
    }

    func open(_ entry: DUEntry) {
        guard entry.isDirectory else { return }
        totals[entry.url] = entry.size
        trail.append(entry.url)
        selected = []
        search = ""
        if let listed = index.get(entry.url.path) {
            entries = listed
            return
        }
        // Deeper than the first scan listed: measure this folder now.
        entries = []
        isScanning = true
        let index = self.index
        let id = scanID
        Task.detached(priority: .userInitiated) {
            _ = DiskScanner.scan(entry.url, index: index) { false }
            await MainActor.run { [weak self] in
                guard let self, self.scanID == id, self.current == entry.url else { return }
                self.entries = index.get(entry.url.path) ?? []
                self.isScanning = false
            }
        }
    }

    func go(to level: Int) {
        guard level < trail.count else { return }
        trail = Array(trail.prefix(level + 1))
        selected = []
        search = ""
        if let url = current { entries = index.get(url.path) ?? [] }
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    func trashSelected() {
        let chosen = selectedEntries.filter { SafetyPolicy.diskUsageBlockReason($0.url, isDirectory: $0.isDirectory) == nil }
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        let index = self.index
        Task.detached {
            let out = Trasher.moveToTrash(chosen.map(\.url), allowAdmin: false)
            for url in out.moved { index.remove(url, size: sizes[url] ?? 0) }
            let freed = out.moved.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for url in self.trail { self.totals[url] = (self.totals[url] ?? 0) - freed }
                if let url = self.current { self.entries = index.get(url.path) ?? [] }
                self.selected.subtract(out.moved)
                self.message = Trasher.summary(out, freed: freed)
            }
        }
    }
}

// MARK: View

struct DiskUsageView: View {
    @ObservedObject var model: DiskUsageModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "chart.bar.doc.horizontal", title: "Disk Usage", status: model.status) {
                Picker("Location", selection: Binding(get: { model.preset }, set: { if let p = $0 { model.scan(p) } })) {
                    ForEach(DiskUsageModel.Preset.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Button("Choose Folder…") { model.chooseFolder() }
                ScanButton(hasScanned: !model.trail.isEmpty, isScanning: model.isScanning) {
                    if let root = model.trail.first { model.scan(root: root) } else { model.scan(model.preset ?? .caches) }
                }
            }
            Divider()
            if model.trail.isEmpty {
                EmptyStateView(icon: "chart.bar.doc.horizontal", title: "See what's using space",
                               message: "TidyLeft measures every folder and lists the biggest first. Open folders to drill down. Caches and logs are safe to clear: apps rebuild them as needed.",
                               buttonTitle: "Scan App Caches", action: { model.scan(.caches) })
            } else {
                breadcrumb
                Divider()
                if model.isScanning && model.entries.isEmpty {
                    ProgressView(model.status).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            Divider()
            TrashFooter(count: model.selectedEntries.count, size: model.selectedSize,
                        disabled: model.selectedEntries.isEmpty || model.isScanning,
                        action: { model.confirm = true }) {
                Text("🔒 items belong to macOS or your main folders and can't be removed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $model.search, prompt: "Filter this folder")
        .confirmationDialog("Move \(model.selectedEntries.count) items to the Trash?", isPresented: $model.confirm,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("Quit the apps they belong to first. Caches are rebuilt automatically; anything else stays in the Trash until you empty it.")
        }
        .resultAlert($model.message)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.trail.enumerated()), id: \.offset) { i, url in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(i == 0 ? Format.path(url) : url.lastPathComponent) { model.go(to: i) }
                        .buttonStyle(.borderless)
                        .fontWeight(i == model.trail.count - 1 ? .semibold : .regular)
                }
                Spacer()
                Text("\(Format.bytes(model.currentTotal)) in this folder")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var list: some View {
        let total = max(model.currentTotal, 1)
        return List {
            ForEach(model.visibleEntries) { entry in
                HStack(spacing: 10) {
                    if entry.blockReason == nil {
                        CheckBox(isOn: model.selected.contains(entry.url)) { _ in model.toggle(entry.url) }
                    } else {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                            .frame(width: 16).help(entry.blockReason ?? "")
                    }
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.appName ?? entry.name).lineLimit(1).truncationMode(.middle)
                        if entry.appName != nil {
                            Text(entry.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let d = entry.modified {
                        Text(d, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                    }
                    SizeBar(fraction: Double(entry.size) / Double(total))
                    Text(String(format: "%.1f%%", Double(entry.size) * 100 / Double(total)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    Text(Format.bytes(entry.size)).monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                    RevealButton(url: entry.url)
                    Button { model.open(entry) } label: { Image(systemName: "chevron.right.circle") }
                        .buttonStyle(.borderless).help("Open folder")
                        .opacity(entry.isDirectory ? 1 : 0).disabled(!entry.isDirectory)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.open(entry) }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}
