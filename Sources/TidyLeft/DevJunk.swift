import SwiftUI

/// Known build and package-manager caches. Each is rebuilt or re-downloaded automatically,
/// so removing it only costs time the next time it's needed. Only these exact folders can
/// be removed from this section.
enum DevJunkCatalog {
    struct Entry: Sendable {
        let group: String
        let title: String
        let detail: String
        let paths: [String]          // relative to the home folder
        var confidence: Confidence = .high
    }

    static let entries: [Entry] = [
        .init(group: "Xcode", title: "Derived data", detail: "Build products and indexes. Xcode rebuilds them on the next build.",
              paths: ["Library/Developer/Xcode/DerivedData"]),
        .init(group: "Xcode", title: "Device support files", detail: "Debug symbols for devices you've connected. Downloaded again the next time you plug one in.",
              paths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                      "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport"]),
        .init(group: "Xcode", title: "Simulator caches", detail: "Cached data for iOS simulators. Recreated as needed.",
              paths: ["Library/Developer/CoreSimulator/Caches"]),
        .init(group: "Xcode", title: "Xcode cache", detail: "Xcode's download and documentation cache.",
              paths: ["Library/Caches/com.apple.dt.Xcode"]),
        .init(group: "Xcode", title: "Archives", detail: "Builds you archived for release. Keep them if you need to read crash reports for versions you've shipped.",
              paths: ["Library/Developer/Xcode/Archives"], confidence: .medium),
        .init(group: "Package managers", title: "Homebrew downloads", detail: "Downloaded installers. Homebrew fetches them again if needed.",
              paths: ["Library/Caches/Homebrew"]),
        .init(group: "Package managers", title: "npm cache", detail: "Downloaded npm packages.", paths: [".npm/_cacache"]),
        .init(group: "Package managers", title: "Yarn cache", detail: "Downloaded Yarn packages.",
              paths: ["Library/Caches/Yarn", ".cache/yarn"]),
        .init(group: "Package managers", title: "pnpm store", detail: "Shared pnpm package store. Projects re-download packages on the next install.",
              paths: ["Library/pnpm/store"], confidence: .medium),
        .init(group: "Package managers", title: "Bun cache", detail: "Downloaded Bun packages.", paths: [".bun/install/cache"]),
        .init(group: "Package managers", title: "pip cache", detail: "Downloaded Python packages.", paths: ["Library/Caches/pip"]),
        .init(group: "Package managers", title: "CocoaPods cache", detail: "Downloaded pods.", paths: ["Library/Caches/CocoaPods"]),
        .init(group: "Package managers", title: "Carthage cache", detail: "Downloaded Carthage dependencies.",
              paths: ["Library/Caches/org.carthage.CarthageKit"]),
        .init(group: "Package managers", title: "Gradle caches", detail: "Downloaded Gradle dependencies and build caches.",
              paths: [".gradle/caches"]),
        .init(group: "Package managers", title: "Maven repository", detail: "Downloaded Java libraries. Re-downloaded on the next build.",
              paths: [".m2/repository"], confidence: .medium),
        .init(group: "Package managers", title: "Cargo registry", detail: "Downloaded Rust crates.",
              paths: [".cargo/registry/cache", ".cargo/registry/src"]),
        .init(group: "Package managers", title: "Go build cache", detail: "Compiled Go packages.", paths: ["Library/Caches/go-build"]),
        .init(group: "Package managers", title: "Composer cache", detail: "Downloaded PHP packages.",
              paths: ["Library/Caches/composer", ".composer/cache"]),
        .init(group: "Editors", title: "VS Code caches", detail: "Visual Studio Code's caches. Your settings and extensions are kept.",
              paths: ["Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData",
                      "Library/Application Support/Code/CachedExtensionVSIXs"]),
        .init(group: "Editors", title: "JetBrains caches", detail: "Caches and indexes for IntelliJ, PyCharm, WebStorm and other JetBrains IDEs. Rebuilt when you open a project.",
              paths: ["Library/Caches/JetBrains"], confidence: .medium),
    ]

    static var allowedPaths: Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Set(entries.flatMap { $0.paths.map { home.appendingPathComponent($0).standardizedFileURL.path } })
    }
}

struct JunkItem: Identifiable, Hashable, Sendable {
    let url: URL
    let group: String
    let title: String
    let detail: String
    let confidence: Confidence
    var size: Int64

    var id: URL { url }
}

@MainActor
final class DevJunkModel: ObservableObject {
    @Published var items: [JunkItem] = []
    @Published var selected: Set<URL> = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var status = "Finds Xcode build files and package-manager caches that are safe to remove."
    @Published var confirm = false
    @Published var message: String?

    var groups: [String] { DevJunkCatalog.entries.map(\.group).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var selectedItems: [JunkItem] { items.filter { selected.contains($0.url) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var allSelected: Bool { !items.isEmpty && items.allSatisfy { selected.contains($0.url) } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        status = "Measuring developer caches…"
        Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var found: [JunkItem] = []
            for entry in DevJunkCatalog.entries {
                for path in entry.paths {
                    let url = home.appendingPathComponent(path)
                    guard FileManager.default.fileExists(atPath: url.path), SafetyPolicy.canRemoveDevJunk(url) else { continue }
                    let size = LeftoverScanner.size(of: url)
                    guard size > 0 else { continue }
                    let suffix = entry.paths.count > 1 ? " (\(url.lastPathComponent))" : ""
                    found.append(JunkItem(url: url, group: entry.group, title: entry.title + suffix, detail: entry.detail,
                                          confidence: entry.confidence, size: size))
                }
            }
            await MainActor.run { [weak self, found] in
                guard let self else { return }
                self.items = found
                self.selected = Set(found.filter { $0.confidence == .high }.map(\.url))
                let total = found.reduce(0) { $0 + $1.size }
                self.status = found.isEmpty ? "No developer caches found."
                    : "\(found.count) caches found · \(Format.bytes(total)) could be freed"
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }

    func selectAll(_ on: Bool) { selected = on ? Set(items.map(\.url)) : [] }

    func trashSelected() {
        let chosen = selectedItems.filter { SafetyPolicy.canRemoveDevJunk($0.url) }
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        Task.detached {
            let out = Trasher.moveToTrash(chosen.map(\.url), allowAdmin: false)
            let freed = out.moved.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items.removeAll { out.moved.contains($0.url) }
                self.selected.subtract(out.moved)
                self.message = Trasher.summary(out, freed: freed)
            }
        }
    }
}

struct DevJunkView: View {
    @ObservedObject var model: DevJunkModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "hammer", title: "Developer Junk", status: model.status) {
                ScanButton(hasScanned: model.hasScanned, isScanning: model.isScanning) { model.scan() }
            }
            Divider()
            if model.items.isEmpty {
                EmptyStateView(
                    icon: model.hasScanned ? "checkmark.seal" : "hammer",
                    title: model.hasScanned ? "Nothing to clean" : "Free up space from developer tools",
                    message: model.hasScanned
                        ? "No Xcode build files or package caches were found."
                        : "Xcode build files, simulator caches and package-manager downloads (Homebrew, npm, pip, Gradle and others) can take tens of gigabytes. They're all rebuilt or downloaded again when needed.",
                    buttonTitle: model.hasScanned || model.isScanning ? nil : "Scan Now",
                    action: { model.scan() })
            } else {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { model.allSelected }, set: { model.selectAll($0) })) {
                        Text("Select all").font(.body.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Label("Everything here is rebuilt or re-downloaded when needed", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
                List {
                    ForEach(model.groups, id: \.self) { group in
                        let rows = model.items.filter { $0.group == group }
                        if !rows.isEmpty {
                            Section(group) {
                                ForEach(rows) { item in
                                    HStack(spacing: 10) {
                                        CheckBox(isOn: model.selected.contains(item.url)) { _ in model.toggle(item.url) }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).font(.body.weight(.medium))
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            Text(Format.path(item.url)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        ConfidenceBadge(confidence: item.confidence, labels: ("Safe to remove", "Check first"))
                                        Text(Format.bytes(item.size)).monospacedDigit()
                                            .frame(width: 80, alignment: .trailing)
                                        RevealButton(url: item.url)
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            TrashFooter(count: model.selectedItems.count, size: model.selectedSize,
                        disabled: model.selectedItems.isEmpty || model.isScanning,
                        action: { model.confirm = true }) { EmptyView() }
        }
        .confirmationDialog("Move \(model.selectedItems.count) caches to the Trash?", isPresented: $model.confirm,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("Quit Xcode and other developer tools first. The space is freed once you empty the Trash.")
        }
        .resultAlert($model.message)
    }
}
