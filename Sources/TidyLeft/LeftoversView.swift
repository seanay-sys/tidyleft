import SwiftUI

struct LeftoversView: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(icon: "sparkles", title: "Leftovers", status: model.status) {
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
                ScanButton(hasScanned: model.hasScanned, isScanning: model.isScanning) { model.scan() }
            }
            Divider()
            if model.visibleGroups.isEmpty {
                emptyState
            } else {
                selectAllBar
                Divider()
                list
            }
            Divider()
            TrashFooter(count: model.selectedItems.count, size: model.selectedSize,
                        disabled: model.selectedItems.isEmpty || model.isScanning,
                        action: { model.confirmTrash = true }) { EmptyView() }
        }
        .searchable(text: $model.search, prompt: "Filter leftovers")
        .confirmationDialog("Move \(model.selectedItems.count) items to the Trash?",
                            isPresented: $model.confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text(model.selectedAdminCount > 0
                 ? "\(model.selectedAdminCount) of them are system-wide, so macOS will ask for your administrator password. Background services are stopped first. Everything stays in the Trash until you empty it."
                 : "They'll stay in the Trash until you empty it, so you can put back anything you still need.")
        }
        .resultAlert($model.message)
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
                                toggle: { model.toggle(item.url) })
                    }
                } label: {
                    HStack(spacing: 10) {
                        CheckBox(isOn: model.isGroupSelected(group)) { model.setGroup(group, selected: $0) }
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
        EmptyStateView(
            icon: model.hasScanned ? "checkmark.seal" : "magnifyingglass",
            title: model.hasScanned ? "Nothing to clean at this level" : "Ready when you are",
            message: model.hasScanned
                ? (model.minConfidence == .high
                   ? "Try “Likely + Possible”, or include app containers."
                   : (model.includeContainers ? "Your Library looks clean." : "Your Library looks clean. You can also include app containers."))
                : "TidyLeft compares your Library folders against every installed app and lists files that no longer have an owner. Nothing is removed until you choose.",
            buttonTitle: model.hasScanned || model.isScanning ? nil : "Scan Now",
            action: { model.scan() })
    }
}

private struct ItemRow: View {
    let item: LeftoverItem
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(isOn: isOn) { _ in toggle() }
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
            RevealButton(url: item.url)
        }
    }
}
