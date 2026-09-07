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
        static let width: CGFloat = 64
        static let widthWithGlyph: CGFloat = 76
        static let height: CGFloat = 30
    }

    private var severity: UsageSeverity?

    var onTap: (() -> Void)?

    init(severity: UsageSeverity? = nil) {
        self.severity = severity
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        bezelStyle = .rounded
        isBordered = true
        imagePosition = .noImage
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
        attributedTitle = title(for: severity)
        toolTip = "AI usage — tap to open"

        let needsGlyph = (severity?.glyph != nil)
        let width = needsGlyph ? Layout.widthWithGlyph : Layout.width
        setFrameSize(NSSize(width: width, height: Layout.height))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// "AI", "AI !" when a provider is in warning, "AI !!" when critical.
    /// Colour is never the only signal — the glyph carries it too.
    private func title(for severity: UsageSeverity?) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        var text = "AI"
        if let glyph = severity?.glyph { text += " \(glyph)" }

        let colour: NSColor
        switch severity {
        case .critical: colour = .systemRed
        case .warning:  colour = .systemOrange
        default:        colour = .labelColor
        }
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
    }

    override var intrinsicContentSize: NSSize { frame.size }
}
