import AppKit
import TouchBarUsageKit

/// One provider's detail page inside usage mode.
///
/// Rows read "5h  72% used  resets in 2h 13m". Two controls are always present:
/// **Back** returns to the combined dashboard, **Close** leaves usage mode
/// entirely and gives macOS its Touch Bar back.
///
/// Provider-agnostic — it renders a `DetailViewModel` and never names a provider.
/// This replaces the Phase 1 `ClaudeDetailView`.
final class ProviderDetailView: NSView {

    enum Layout {
        static let width: CGFloat = 1000
        static let height: CGFloat = 30
    }

    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onInteraction: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")

    init(detail: DetailViewModel, mascot: NSImage?) {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor

        rowsStack.orientation = .horizontal
        rowsStack.spacing = 18
        rowsStack.alignment = .centerY

        let back = NSButton(title: "‹ Back", target: self, action: #selector(handleBack))
        back.bezelStyle = .rounded
        back.font = .systemFont(ofSize: 12, weight: .medium)

        let close = NSButton(title: "Close", target: self, action: #selector(handleClose))
        close.bezelStyle = .rounded
        close.font = .systemFont(ofSize: 12, weight: .medium)

        var views: [NSView] = [back]
        if let mascot {
            let imageView = NSImageView()
            imageView.image = mascot
            imageView.imageScaling = .scaleNone
            views.append(imageView)
        }
        views.append(contentsOf: [titleLabel, rowsStack, footerLabel, close])

        let root = NSStackView(views: views)
        root.orientation = .horizontal
        root.spacing = 14
        root.alignment = .centerY
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            root.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ detail: DetailViewModel) {
        titleLabel.stringValue = detail.title
        footerLabel.stringValue = detail.footer

        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in detail.rows {
            rowsStack.addArrangedSubview(makeRow(row))
        }
        if detail.rows.isEmpty {
            let empty = NSTextField(labelWithString: detail.footer)
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(empty)
        }
    }

    private func makeRow(_ row: DetailViewModel.Row) -> NSView {
        let label = NSTextField(labelWithString: row.label)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor

        let usage = NSTextField(labelWithString: row.usage)
        usage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        usage.textColor = color(for: row.severity)

        let reset = NSTextField(labelWithString: row.reset)
        reset.font = .systemFont(ofSize: 11)
        reset.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [label, usage, reset])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    private func color(for severity: UsageSeverity) -> NSColor {
        switch severity {
        case .normal, .elevated: return .labelColor
        case .warning:           return .systemOrange
        case .critical:          return .systemRed
        }
    }

    @objc private func handleBack() {
        onInteraction?()
        onBack?()
    }

    @objc private func handleClose() { onClose?() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }
}
