import AppKit
import TouchBarUsageKit

/// The compact widget: mascot plus the two headline percentages.
///
/// Implemented as an `NSButton` rather than a custom `NSView`. The Touch Bar
/// routes touches to controls it recognises; a plain view receives neither
/// gesture-recogniser callbacks nor `mouseDown` there, so a custom view is
/// visible but dead. This was measured on macOS 26.6.2 — both approaches were
/// tried on the physical bar before settling here.
///
/// Text is laid out against the width actually granted, and degrades by dropping
/// the provider name before it would ever truncate a percentage.
final class ClaudeCompactView: NSButton {

    private var viewModel: TouchBarViewModel

    private enum Layout {
        /// Budget for the mascot. The pixel renderer snaps down to a whole
        /// number of grid cells, so 30 yields 2pt cells and a legible creature.
        static let mascotHeight: CGFloat = 30
        /// Slack so a fractional text width never clips the final character.
        static let textSlack: CGFloat = 30
        static let maximumWidth: CGFloat = 300
    }

    var onTap: (() -> Void)?

    init(viewModel: TouchBarViewModel) {
        self.viewModel = viewModel
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 30))

        bezelStyle = .rounded
        isBordered = true
        imagePosition = .imageLeading
        // .scaleNone keeps generated pixel art at its rendered size; scaling it
        // would reintroduce the blur the renderer works to avoid.
        imageScaling = .scaleNone
        image = MascotProvider.mascot(height: Layout.mascotHeight, severity: viewModel.severity)
        target = self
        action = #selector(handleTap)

        apply(viewModel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap() {
        guard viewModel.isInteractive else { return }
        onTap?()
    }

    /// The pose always reflects real usage — there is no override or demo mode,
    /// so the creature can never misreport the severity band.
    private func refreshMascot() {
        image = MascotProvider.mascot(height: Layout.mascotHeight, severity: viewModel.severity)
        invalidateIntrinsicContentSize()
        // The Touch Bar does not always repaint a hosted control just because its
        // image property changed; ask explicitly.
        needsDisplay = true
        superview?.needsDisplay = true
    }

    func apply(_ viewModel: TouchBarViewModel) {
        let severityChanged = viewModel.severity != self.viewModel.severity
        self.viewModel = viewModel
        // The mascot is redrawn only when the severity band changes, so there is
        // no animation loop and no idle work.
        if image == nil || severityChanged {
            refreshMascot()
        }
        attributedTitle = attributedText(for: viewModel)
        toolTip = viewModel.compactText
        isEnabled = true
        invalidateIntrinsicContentSize()
    }

    /// Chooses the widest string that fits, then colours only the severe parts.
    /// Colour is always paired with the glyph the view model already embedded, so
    /// severity never depends on hue alone.
    private func attributedText(for viewModel: TouchBarViewModel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let budget = Layout.maximumWidth - Layout.mascotHeight - Layout.textSlack

        let full = viewModel.compactText
        let text = width(of: full, font: font) <= budget ? full : viewModel.condensedText

        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])

        for segment in viewModel.segments where segment.severity == .warning || segment.severity == .critical {
            let range = (text as NSString).range(of: segment.combined)
            if range.location != NSNotFound {
                result.addAttribute(.foregroundColor, value: color(for: segment.severity), range: range)
            }
        }
        if viewModel.statusText != nil {
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func color(for severity: UsageSeverity) -> NSColor {
        switch severity {
        case .normal, .elevated: return .labelColor
        case .warning:           return .systemOrange
        case .critical:          return .systemRed
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: min(Layout.maximumWidth, base.width + Layout.textSlack),
                      height: 30)
    }
}
