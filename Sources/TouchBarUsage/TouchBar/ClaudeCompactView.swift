import AppKit
import TouchBarUsageKit

/// The Control Strip widget: mascot plus the two headline percentages.
///
/// Lays out against the width actually granted rather than a hard-coded pixel
/// count, and degrades by dropping the provider name before it would ever
/// truncate a percentage into something unreadable.
final class ClaudeCompactView: NSView {

    private let mascot = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var viewModel: TouchBarViewModel

    /// Widths available to a Control Strip item; the wider layout is used when
    /// the measured text fits.
    private enum Layout {
        static let mascotSize: CGFloat = 18
        static let spacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 8
        /// Slack so a fractional text width never clips the final character.
        static let textSlack: CGFloat = 6
        static let maximumWidth: CGFloat = 280
    }

    var onTap: (() -> Void)?

    init(viewModel: TouchBarViewModel) {
        self.viewModel = viewModel
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 30))

        mascot.image = MascotProvider.mascot(height: Layout.mascotSize)
        mascot.imageScaling = .scaleProportionallyUpOrDown
        mascot.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(mascot)
        addSubview(label)

        NSLayoutConstraint.activate([
            mascot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalPadding),
            mascot.centerYAnchor.constraint(equalTo: centerYAnchor),
            mascot.widthAnchor.constraint(equalToConstant: Layout.mascotSize),
            mascot.heightAnchor.constraint(equalToConstant: Layout.mascotSize),

            label.leadingAnchor.constraint(equalTo: mascot.trailingAnchor, constant: Layout.spacing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -Layout.horizontalPadding),
            widthAnchor.constraint(lessThanOrEqualToConstant: Layout.maximumWidth),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(click)

        apply(viewModel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap() {
        guard viewModel.isInteractive else { return }
        onTap?()
    }

    func apply(_ viewModel: TouchBarViewModel) {
        self.viewModel = viewModel
        label.attributedStringValue = attributedText(for: viewModel)
        label.toolTip = viewModel.compactText
        invalidateIntrinsicContentSize()
    }

    /// Chooses the widest string that fits, then colours only the severe parts.
    /// Colour is always paired with the glyph the view model already embedded,
    /// so severity never depends on hue alone.
    private func attributedText(for viewModel: TouchBarViewModel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let budget = Layout.maximumWidth - Layout.mascotSize - Layout.spacing
            - Layout.horizontalPadding * 2 - Layout.textSlack

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
        let textWidth = ceil(label.attributedStringValue.size().width) + Layout.textSlack
        let width = min(Layout.maximumWidth,
                        Layout.horizontalPadding * 2 + Layout.mascotSize + Layout.spacing + textWidth)
        return NSSize(width: width, height: 30)
    }
}
