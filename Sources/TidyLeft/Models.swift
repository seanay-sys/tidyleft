import Foundation

enum Confidence: Int, Comparable, CaseIterable, Identifiable, Sendable {
    case low = 0, medium = 1, high = 2

    var id: Int { rawValue }
    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .high: return "Likely leftover"
        case .medium: return "Possible leftover"
        case .low: return "Uncertain"
        }
    }
}

struct LeftoverItem: Identifiable, Hashable, Sendable {
    let url: URL
    let category: String
    let confidence: Confidence
    let reason: String
    let modified: Date?
    var size: Int64 = 0
    var requiresAdmin = false   // lives under /Library; removing it needs an administrator

    var id: URL { url }
}

struct LeftoverGroup: Identifiable, Sendable {
    let id: String          // normalized identifier, used for grouping
    var displayName: String
    var items: [LeftoverItem]

    var confidence: Confidence { items.map(\.confidence).max() ?? .low }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var reason: String { items.max(by: { $0.confidence < $1.confidence })?.reason ?? "" }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func path(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
