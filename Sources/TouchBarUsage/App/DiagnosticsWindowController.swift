import AppKit
import TouchBarUsageKit

/// A read-only diagnostics sheet. Everything shown here is safe to paste into a
/// public bug report: presence and status only, never a token, credential blob,
/// account identifier, or raw provider payload.
@MainActor
final class DiagnosticsWindowController: NSWindowController {

    private let textView = NSTextView()
    private var currentReport = ""

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Touch Bar Usage — Diagnostics"
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = textView

        let copyButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyReport))
        copyButton.bezelStyle = .rounded

        let stack = NSStackView(views: [scroll, copyButton])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)

        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    func show(report: [DiagnosticEntry]) {
        currentReport = report.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        textView.string = currentReport
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    /// Copies exactly the text on screen, which is built only from
    /// `DiagnosticEntry` values that providers guarantee are non-sensitive.
    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentReport, forType: .string)
    }
}
