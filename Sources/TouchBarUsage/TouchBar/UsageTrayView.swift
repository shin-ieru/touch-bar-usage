import AppKit
import TouchBarUsageKit

/// The small persistent Control Strip entry point shown in **normal mode**.
///
/// This is an entry point, not a dashboard: it shows an "AI" mark plus a
/// severity glyph, and nothing else. The Control Strip slot is narrow and fixed,
/// so packing both providers' numbers in here would either overflow or shrink the
/// text past readability — the expanded usage bar exists for that.
///
/// Implemented as an `NSButton` because a plain `NSView` in a Touch Bar item
/// receives no touch events at all, and given a concrete frame because an Auto
/// Layout-only view collapses to zero width and is never drawn.
final class UsageTrayView: NSButton {

    private enum Layout {
        /// Kept deliberately tight. The Control Strip slot does not widen to fit.
        static let height: CGFloat = 30
        /// Horizontal padding around the badge inside the button. Kept tight:
        /// the Control Strip slot does not grow, and padding spent here is width
        /// taken from the artwork.
        static let padding: CGFloat = 7
        /// Extra room for the severity glyph when one is shown.
        static let glyphWidth: CGFloat = 14
        /// Floor, so the button stays comfortably tappable even if a badge is
        /// unusually narrow.
        static let minimumWidth: CGFloat = 56
    }

    private var severity: UsageSeverity?

    var onTap: (() -> Void)?

    init(severity: UsageSeverity? = nil) {
        self.severity = severity
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.minimumWidth, height: Layout.height))
        bezelStyle = .rounded
        isBordered = true
        // The badge carries the identity; the glyph is a trailing severity cue.
        imagePosition = .imageLeading
        imageScaling = .scaleNone
        target = self
        action = #selector(handleTap)
        apply(severity: severity)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap() { onTap?() }

    /// `severity` is the worst band across all providers, or nil when nothing has
    /// loaded yet.
    func apply(severity: UsageSeverity?) {
        self.severity = severity

        let badge = CombinedTrayBadgeResolver.badge()
        image = badge
        attributedTitle = glyphTitle(for: severity)

        // Sized to the badge actually resolved, rather than a fixed guess, so a
        // local override of a different aspect ratio still fits without clipping.
        var width = badge.size.width + Layout.padding * 2
        if severity?.glyph != nil { width += Layout.glyphWidth }
        setFrameSize(NSSize(width: max(width.rounded(), Layout.minimumWidth),
                            height: Layout.height))

        toolTip = "Claude + Codex usage — tap to open"
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The badge is the identity; this adds only the severity cue — "!" at
    /// warning, "!!" at critical. Colour is never the sole signal, and at normal
    /// or elevated there is no text at all, keeping the slot as narrow as
    /// possible.
    private func glyphTitle(for severity: UsageSeverity?) -> NSAttributedString {
        guard let glyph = severity?.glyph else { return NSAttributedString(string: "") }

        let colour: NSColor = (severity == .critical) ? .systemRed : .systemOrange
        return NSAttributedString(
            string: " \(glyph)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: colour,
            ])
    }

    override var intrinsicContentSize: NSSize { frame.size }
}
