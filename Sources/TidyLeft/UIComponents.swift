import AppKit
import SwiftUI

/// Header shared by every section: icon, title, a status line and section controls.
struct PaneHeader<Controls: View>: View {
    let icon: String
    let title: String
    let status: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            controls
        }
        .padding(16)
    }
}

/// Prominent Scan / Rescan button that never truncates its label.
struct ScanButton: View {
    let hasScanned: Bool
    let isScanning: Bool
    var title = "Scan"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isScanning {
                ProgressView().controlSize(.small).frame(minWidth: 80)
            } else {
                Label(hasScanned ? "Rescan" : title, systemImage: "magnifyingglass")
                    .fixedSize()
                    .frame(minWidth: 80)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isScanning)
        .layoutPriority(1)
    }
}

/// Centered placeholder for an empty list.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

/// Footer with the selection summary and the Move to Trash button.
struct TrashFooter<Leading: View>: View {
    let count: Int
    let size: Int64
    var buttonTitle = "Move to Trash"
    let disabled: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack {
            leading
            Spacer()
            Text("\(count) selected · \(Format.bytes(size))")
                .monospacedDigit().foregroundStyle(.secondary)
            Button(role: .destructive, action: action) {
                Label(buttonTitle, systemImage: "trash")
            }
            .controlSize(.large)
            .disabled(disabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence
    var labels: (high: String, medium: String) = ("Likely leftover", "Possible leftover")

    var body: some View {
        let color: Color = switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .gray
        }
        Text(confidence == .high ? labels.high : confidence == .medium ? labels.medium : "Uncertain")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Horizontal bar showing an item's share of the total (TreeSize style).
struct SizeBar: View {
    let fraction: Double
    var width: CGFloat = 140

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(Color.accentColor.opacity(0.75))
                .frame(width: max(2, width * CGFloat(min(max(fraction, 0), 1))))
        }
        .frame(width: width, height: 8)
    }
}

/// Small "Show in Finder" button.
struct RevealButton: View {
    let url: URL

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Image(systemName: "magnifyingglass.circle")
        }
        .buttonStyle(.borderless).help("Show in Finder")
    }
}

/// A checkbox bound to a get/set pair, without needing @State.
struct CheckBox: View {
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.checkbox).labelsHidden()
    }
}

extension View {
    /// The alert every section shows when a cleanup finishes.
    func resultAlert(_ message: Binding<String?>) -> some View {
        alert("Cleanup finished", isPresented: Binding(get: { message.wrappedValue != nil },
                                                       set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

enum AppName {
    /// "Google Chrome" for "com.google.Chrome", when that app is installed.
    static func forBundleID(_ id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
