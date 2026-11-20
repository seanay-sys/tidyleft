import Foundation

/// Moves items to the Trash. Items the user owns are moved directly; anything outside
/// the home folder that can't be moved that way (root-owned apps, /Library files) is
/// retried with a single administrator prompt. Nothing is ever deleted outright.
enum Trasher {
    struct Outcome: Sendable {
        var moved = Set<URL>()
        var failures: [String] = []
    }

    static func moveToTrash(_ urls: [URL], allowAdmin: Bool) -> Outcome {
        var out = Outcome()
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        var needAdmin: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                out.moved.insert(url)
            } catch {
                if allowAdmin, !url.path.hasPrefix(home) {
                    needAdmin.append(url)
                } else {
                    out.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !needAdmin.isEmpty {
            let admin = PrivilegedRemover.moveToTrash(needAdmin)
            out.moved.formUnion(admin.moved)
            if admin.cancelled {
                out.failures.append("\(needAdmin.count) item\(needAdmin.count == 1 ? "" : "s") skipped — administrator access was cancelled")
            }
            out.failures += admin.failed.map { "\($0.0.lastPathComponent): \($0.1)" }
        }
        return out
    }

    /// One-line summary for the alert shown after a cleanup.
    static func summary(_ out: Outcome, freed: Int64) -> String {
        var text = "Moved \(out.moved.count) item\(out.moved.count == 1 ? "" : "s") to the Trash (about \(Format.bytes(freed)))."
        if !out.failures.isEmpty {
            text += "\n\nNot moved — Full Disk Access often fixes this:\n" + out.failures.prefix(8).joined(separator: "\n")
        }
        if freed >= Support.mentionThreshold { text += "\n\n" + Support.coffeeLine }
        return text
    }
}
