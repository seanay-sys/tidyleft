import SwiftUI

struct ContentView: View {
    @StateObject private var model = CleanerModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                if model.visibleGroups.isEmpty {
                    emptyState
                } else {
                    selectAllBar
                    Divider()
                    list
                }
                Divider()
                footer
            }
            .searchable(text: $model.search, prompt: "Filter leftovers")
        }
        .frame(minWidth: 860, minHeight: 580)
        .confirmationDialog("Move \(model.selectedItems.count) items to the Trash?",
                            isPresented: $model.confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text(model.selectedAdminCount > 0
                 ? "\(model.selectedAdminCount) of them are system-wide, so macOS will ask for your administrator password. Background services are stopped first. Everything stays in the Trash until you empty it."
                 : "They'll stay in the Trash until you empty it, so you can put back anything you still need.")
        }
        .alert("Cleanup finished", isPresented: Binding(get: { model.message != nil },
                                                         set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Leftover Cleaner").font(.title2.bold())
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Show", selection: $model.minConfidence) {
                Text("Likely").tag(Confidence.high)
                Text("Likely + Possible").tag(Confidence.medium)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
            Toggle("System-wide", isOn: $model.includeSystem)
                .help("Also scan /Library: shared support files, launch daemons and privileged helper tools. Removing these asks for your administrator password.")
            Toggle("App containers", isOn: $model.includeContainers)
                .help("Also scan ~/Library/Containers and Group Containers. macOS may ask for permission; Full Disk Access avoids that.")
            Button {
                model.scan()
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else {
                    Label(model.hasScanned ? "Rescan" : "Scan", systemImage: "magnifyingglass")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning)
        }
        .padding(16)
    }

    private var selectAllBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.allVisibleSelected },
                                 set: { model.selectAllVisible($0) })) {
                Text("Select all leftovers").font(.body.weight(.medium))
            }
            .toggleStyle(.checkbox)
            Text("\(model.visibleItems.count) items · \(Format.bytes(model.visibleItems.reduce(0) { $0 + $1.size }))")
                .foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Label("Third-party apps only — macOS files are never listed", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var list: some View {
        List {
            ForEach(model.visibleGroups) { group in
                DisclosureGroup {
                    ForEach(group.items) { item in
                        ItemRow(item: item, isOn: model.selected.contains(item.url),
                                toggle: { model.toggle(item.url) },
                                reveal: { model.reveal(item.url) })
                    }
                } label: {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { model.isGroupSelected(group) },
                                                 set: { model.setGroup(group, selected: $0) }))
                            .toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName).font(.body.weight(.medium))
                            Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s") · \(group.reason)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ConfidenceBadge(confidence: group.confidence)
                        Text(Format.bytes(group.totalSize))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: model.hasScanned ? "checkmark.seal" : "magnifyingglass")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text(model.hasScanned ? "Nothing to clean at this level" : "Ready when you are")
                .font(.title3.weight(.semibold))
            Text(model.hasScanned
                 ? "Try “Likely + Possible”, or include app containers."
                 : "Leftover Cleaner compares your Library folders against every installed app\nand lists files that no longer have an owner. Nothing is removed until you choose.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if !model.hasScanned {
                Button("Scan Now") { model.scan() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isScanning)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .help("Lets the app see and clean protected folders without repeated prompts.")
            Spacer()
            Text("\(model.selectedItems.count) selected · \(Format.bytes(model.selectedSize))")
                .monospacedDigit().foregroundStyle(.secondary)
            Button(role: .destructive) {
                model.confirmTrash = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .controlSize(.large)
            .disabled(model.selectedItems.isEmpty || model.isScanning)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct ItemRow: View {
    let item: LeftoverItem
    let isOn: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .toggleStyle(.checkbox).labelsHidden()
            HStack(spacing: 4) {
                if item.requiresAdmin {
                    Image(systemName: "lock.fill").font(.caption2)
                        .help("System-wide item in /Library — removing it needs your administrator password")
                }
                Text(item.category)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(item.requiresAdmin ? AnyShapeStyle(Color.orange.opacity(0.18)) : AnyShapeStyle(.quaternary), in: Capsule())
            .frame(width: 150, alignment: .leading)
            Text(Format.path(item.url))
                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .help(item.reason)
            Spacer()
            if let d = item.modified {
                Text(d, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.bytes(item.size)).monospacedDigit().font(.callout)
                .frame(width: 80, alignment: .trailing)
            Button(action: reveal) { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }
}

private struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        let color: Color = switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .gray
        }
        Text(confidence.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
