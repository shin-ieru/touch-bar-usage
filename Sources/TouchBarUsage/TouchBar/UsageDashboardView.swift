import AppKit
import TouchBarUsageKit

/// The expanded dashboard shown in **usage mode**: every provider side by side,
/// plus a Close control that always stays reachable.
///
/// Deliberately provider-agnostic — it renders whatever entries it is given, so a
/// third provider would need no change here. It carries a concrete frame because
/// an Auto Layout-only view is never drawn in a Touch Bar item.
final class UsageDashboardView: NSView {

    enum Layout {
        /// The dashboard is intentionally temporary, so it may use the full strip.
        static let width: CGFloat = 1000
        static let height: CGFloat = 30
        static let closeWidth: CGFloat = 60
    }

    /// Tapping a provider opens its detail page.
    var onSelectProvider: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// Any interaction resets the auto-dismiss timer.
    var onInteraction: (() -> Void)?

    private let stack = NSStackView()

    init(model: DashboardViewModel) {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))

        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ model: DashboardViewModel) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for entry in model.entries {
            stack.addArrangedSubview(providerButton(for: entry))
        }

        let close = NSButton(title: "Close", target: self, action: #selector(handleClose))
        close.bezelStyle = .rounded
        close.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(close)
    }

    /// One provider chip: mascot, name, and its two headline percentages.
    private func providerButton(for entry: DashboardViewModel.Entry) -> NSButton {
        let button = ProviderChipButton(providerID: entry.providerID)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        button.image = MascotProvider.mascot(
            for: entry.providerID,
            height: 30,
            severity: entry.severity ?? .normal)
        button.attributedTitle = chipTitle(for: entry)
        button.target = self
        button.action = #selector(handleProvider(_:))
        button.toolTip = entry.compact.compactText
        return button
    }

    private func chipTitle(for entry: DashboardViewModel.Entry) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        // Provider name plus values; the view model already embeds severity
        // glyphs and the stale marker.
        let text = entry.compact.compactText
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])

        for segment in entry.compact.segments
        where segment.severity == .warning || segment.severity == .critical {
            let range = (text as NSString).range(of: segment.combined)
            if range.location != NSNotFound {
                result.addAttribute(.foregroundColor,
                                    value: segment.severity == .critical
                                        ? NSColor.systemRed : NSColor.systemOrange,
                                    range: range)
            }
        }
        if entry.compact.statusText != nil {
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    @objc private func handleProvider(_ sender: NSButton) {
        onInteraction?()
        guard let chip = sender as? ProviderChipButton else { return }
        onSelectProvider?(chip.providerID)
    }

    @objc private func handleClose() {
        onClose?()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }
}

/// Carries the provider identity through the target/action callback.
private final class ProviderChipButton: NSButton {
    let providerID: String
    init(providerID: String) {
        self.providerID = providerID
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
