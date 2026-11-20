import AppKit

/// The optional "buy me a coffee" tip link. It only opens the Ko-fi page in the browser:
/// the app never handles payments and sends nothing anywhere.
enum Support {
    static let kofi = URL(string: "https://ko-fi.com/seanaysys")!
    static let github = URL(string: "https://github.com/seanay-sys/tidyleft")!
    /// Cleanups at least this big get a one-line tip mention in the result message.
    static let mentionThreshold: Int64 = 500 * 1_000_000
    static let coffeeLine = "If TidyLeft helped, you can buy me a coffee ☕ (a thank-you, not a purchase)."

    static func openKofi() { NSWorkspace.shared.open(kofi) }

    /// Standard About panel with the version, plus GitHub and Ko-fi links.
    @MainActor static func showAbout() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                   .foregroundColor: NSColor.secondaryLabelColor]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        func add(_ text: String, link: URL? = nil) {
            var attrs = body
            attrs[.paragraphStyle] = para
            if let link { attrs[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attrs))
        }
        add("Free and open source (MIT). Use at your own risk: no warranty, no support.\n\n")
        add("Source code on GitHub", link: github)
        add("   ·   ")
        add("Buy me a coffee ☕", link: kofi)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
