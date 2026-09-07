import AppKit
import TouchBarUsageKit

/// Secondary UI: a status item exposing usage text, refresh, and settings.
/// The Touch Bar is the product; this menu exists for control and diagnosis.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var state: ProviderState = .loading

    var onRefresh: (() -> Void)?
    var onToggleTouchBar: ((Bool) -> Void)?
    var onShowDiagnostics: (() -> Void)?
    var onQuit: (() -> Void)?

    private(set) var isTouchBarEnabled = true
    private var touchBarSupported = true

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                   accessibilityDescription: "Touch Bar Usage")
            button.image?.isTemplate = true
        }
        statusItem.menu = menu
        menu.delegate = self
        rebuild()
    }

    func update(state: ProviderState) {
        self.state = state
        rebuild()
    }

    func setTouchBarSupported(_ supported: Bool) {
        touchBarSupported = supported
        if !supported { isTouchBarEnabled = false }
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Touch Bar Usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addProviderSection()

        menu.addItem(.separator())
        menu.addItem(item(title: "Refresh Now", action: #selector(refresh), key: "r"))

        let touchBarItem = item(
            title: touchBarSupported ? "Touch Bar: \(isTouchBarEnabled ? "On" : "Off")"
                                     : "Touch Bar: Unsupported",
            action: touchBarSupported ? #selector(toggleTouchBar) : nil,
            key: "")
        touchBarItem.state = isTouchBarEnabled ? .on : .off
        menu.addItem(touchBarItem)

        let loginItem = item(title: "Launch at Login", action: #selector(toggleLoginItem), key: "")
        loginItem.state = LoginItemService.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(item(title: "Diagnostics…", action: #selector(showDiagnostics), key: ""))
        menu.addItem(item(title: "About Touch Bar Usage", action: #selector(showAbout), key: ""))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit", action: #selector(quit), key: "q"))
    }

    /// Usage lines, or an actionable explanation when there is nothing to show.
    private func addProviderSection() {
        let name = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)

        switch state {
        case .needsAuthentication:
            menu.addItem(disabled("Authentication required"))
            // Deliberately advisory: this app never opens or mutates auth itself.
            menu.addItem(disabled("Open Claude Code to sign in / refresh"))
            return
        case .notInstalled:
            menu.addItem(disabled("Claude Code not found"))
            return
        case .loading:
            menu.addItem(disabled("Loading…"))
            return
        case .offline where state.snapshot == nil:
            menu.addItem(disabled("Offline"))
            return
        case .rateLimited where state.snapshot == nil:
            menu.addItem(disabled("Rate limited — try later"))
            return
        case .failed, .unsupported:
            menu.addItem(disabled("Usage unavailable"))
            return
        default:
            break
        }

        guard let snapshot = state.snapshot else {
            menu.addItem(disabled("No usage data"))
            return
        }

        let detail = DetailViewModel.make(state: state)
        for row in detail.rows {
            menu.addItem(disabled("\(row.label): \(row.usage) · \(row.reset)"))
        }
        menu.addItem(disabled("Updated: \(ResetFormatter.age(since: snapshot.fetchedAt))"))
        if case .stale(_, let reason) = state {
            menu.addItem(disabled("Showing cached data\(reason.map { " (\($0))" } ?? "")"))
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(title: String, action: Selector?, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func refresh() { onRefresh?() }

    @objc private func toggleTouchBar() {
        isTouchBarEnabled.toggle()
        onToggleTouchBar?(isTouchBarEnabled)
        rebuild()
    }

    @objc private func toggleLoginItem() {
        let target = !LoginItemService.isEnabled
        if !LoginItemService.setEnabled(target) {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = """
            macOS registers login items only for apps in a standard location. \
            Build the app bundle and move Touch Bar Usage to /Applications, then try again.

            Status: \(LoginItemService.statusDescription)
            """
            alert.runModal()
        }
        rebuild()
    }

    /// Steps the Touch Bar mascot through each pose, then back to live. Only the
    /// mascot changes; the percentages keep showing real usage throughout.
    @objc private func showDiagnostics() { onShowDiagnostics?() }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Touch Bar Usage"
        alert.informativeText = """
        Claude Code usage on your MacBook Pro Touch Bar.

        An independent open-source project. Not affiliated with, endorsed by, \
        or sponsored by Anthropic.
        """
        alert.runModal()
    }

    @objc private func quit() { onQuit?() }
}

extension MenuBarController: NSMenuDelegate {
    /// Rebuild on open so the "Updated Nm ago" line is accurate without a timer.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }
}
