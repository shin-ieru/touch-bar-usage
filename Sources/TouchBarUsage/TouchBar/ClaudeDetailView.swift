import AppKit
import TouchBarUsageKit

/// The expanded presentation shown after tapping the compact widget.
///
/// Rows read "5h   72% used   resets in 2h 13m", with a footer showing data age.
/// A "Done" button returns to compact mode; the physical Escape key on this
/// hardware also dismisses it, so no synthetic Escape item is added.
final class ClaudeDetailView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let doneButton: NSButton

    var onDone: (() -> Void)?

    init(detail: DetailViewModel) {
        doneButton = NSButton(title: "Done", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 30))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor

        rowsStack.orientation = .horizontal
        rowsStack.spacing = 18
        rowsStack.alignment = .centerY

        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(handleDone)

        let root = NSStackView(views: [titleLabel, rowsStack, footerLabel, doneButton])
        root.orientation = .horizontal
        root.spacing = 14
        root.alignment = .centerY
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            root.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleDone() { onDone?() }

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
        case .normal:   return .labelColor
        case .elevated: return .labelColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }
}
