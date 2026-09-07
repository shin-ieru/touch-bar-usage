import AppKit
import TouchBarUsageKit

/// Secondary UI: a status item exposing every provider's usage, a manual
/// refresh, and settings.
///
/// "Show Usage on Touch Bar" opens the same expanded dashboard as tapping the
/// tray item. That is deliberate redundancy: if a future macOS stops rendering
/// third-party Control Strip items, the menu remains a working way in.
@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var model = DashboardViewModel(entries: [])

    private var traySupported = true
    private var trayInstalled = false
    private var usageBarSupported = true

    var onRefresh: (() -> Void)?
    var onShowUsageBar: (() -> Void)?
    var onShowDiagnostics: (() -> Void)?
    var onQuit: (() -> Void)?

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

    func update(model: DashboardViewModel) {
        self.model = model
        updateStatusButton()
        rebuild()
    }

    /// The menu bar icon carries the at-a-glance signal.
    ///
    /// This matters more than it looks: third-party Control Strip items are not
    /// rendered on macOS 26, so the Touch Bar shows nothing until the user opens
    /// usage mode. Without this, a provider hitting its limit would be invisible.
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let severity = model.worstSeverity

        let symbol: String
        switch severity {
        case .critical: symbol = "gauge.with.dots.needle.100percent"
        case .warning:  symbol = "gauge.with.dots.needle.67percent"
        case .elevated: symbol = "gauge.with.dots.needle.50percent"
        default:        symbol = "gauge.with.dots.needle.33percent"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AI usage")
        button.image?.isTemplate = true

        // Severity is never colour-only: warning and critical add a glyph, which
        // also survives a monochrome menu bar.
        button.attributedTitle = NSAttributedString(
            string: severity?.glyph.map { " \($0)" } ?? "",
            attributes: [
                .foregroundColor: severity == .critical ? NSColor.systemRed : NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            ])
        button.toolTip = model.entries
            .map { "\($0.displayName): \($0.compact.condensedText)" }
            .joined(separator: "\n")
    }

    func setTouchBarStatus(traySupported: Bool, trayInstalled: Bool, usageBarSupported: Bool) {
        self.traySupported = traySupported
        self.trayInstalled = trayInstalled
        self.usageBarSupported = usageBarSupported
        rebuild()
    }

    /// "Updated Nm ago" rows, kept so they can be refreshed without rebuilding.
    private var ageLines: [(item: NSMenuItem, fetchedAt: Date)] = []

    private func refreshAgeLines() {
        for line in ageLines {
            line.item.title = "Updated: \(ResetFormatter.age(since: line.fetchedAt))"
        }
    }

    private func rebuild() {
        menu.removeAllItems()
        ageLines.removeAll()

        let header = NSMenuItem(title: "Touch Bar Usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for entry in model.entries {
            menu.addItem(.separator())
            addSection(for: entry)
        }
        if model.entries.isEmpty {
            menu.addItem(disabled("Loading…"))
        }

        menu.addItem(.separator())

        let showItem = item(title: "Show Usage on Touch Bar",
                            action: usageBarSupported ? #selector(showUsageBar) : nil,
                            key: "u")
        if !usageBarSupported { showItem.toolTip = "Touch Bar APIs unavailable on this system" }
        menu.addItem(showItem)

        menu.addItem(item(title: "Refresh Now", action: #selector(refresh), key: "r"))

        let loginItem = item(title: "Launch at Login", action: #selector(toggleLoginItem), key: "")
        loginItem.state = LoginItemService.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(disabled(touchBarStatusText))
        menu.addItem(item(title: "Diagnostics…", action: #selector(showDiagnostics), key: ""))
        menu.addItem(item(title: "About Touch Bar Usage", action: #selector(showAbout), key: ""))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit", action: #selector(quit), key: "q"))
    }

    private var touchBarStatusText: String {
        if !usageBarSupported { return "Touch Bar: unsupported" }
        if !traySupported { return "Touch Bar: menu only" }
        return trayInstalled ? "Touch Bar: tray item active" : "Touch Bar: tray item unavailable"
    }

    /// Usage lines, or an actionable explanation when there is nothing to show.
    /// Each provider gets its own guidance — "open Claude Code to sign in" is
    /// wrong advice for a Codex problem.
    private func addSection(for entry: DashboardViewModel.Entry) {
        let name = NSMenuItem(title: entry.displayName, action: nil, keyEquivalent: "")
        name.isEnabled = false
        menu.addItem(name)

        switch entry.state {
        case .needsAuthentication:
            menu.addItem(disabled("Authentication required"))
            menu.addItem(disabled(signInHint(for: entry.providerID)))
            return
        case .notInstalled:
            menu.addItem(disabled("\(installName(for: entry.providerID)) not found"))
            return
        case .loading:
            menu.addItem(disabled("Loading…"))
            return
        case .offline where entry.state.snapshot == nil:
            menu.addItem(disabled("Offline"))
            return
        case .rateLimited where entry.state.snapshot == nil:
            menu.addItem(disabled("Rate limited — try later"))
            return
        case .failed, .unsupported:
            menu.addItem(disabled("Usage unavailable"))
            return
        default:
            break
        }

        guard let snapshot = entry.state.snapshot else {
            menu.addItem(disabled("No usage data"))
            return
        }

        let detail = entry.detail()
        for row in detail.rows {
            menu.addItem(disabled("\(row.label): \(row.usage) · \(row.reset)"))
        }
        // A provider that reports no short window says so rather than showing 0%.
        if snapshot.shortWindow == nil {
            menu.addItem(disabled("5-hour limit: not reported"))
        }
        let updated = disabled("Updated: \(ResetFormatter.age(since: snapshot.fetchedAt))")
        ageLines.append((item: updated, fetchedAt: snapshot.fetchedAt))
        menu.addItem(updated)
        if case .stale(_, let reason) = entry.state {
            menu.addItem(disabled("Showing cached data\(reason.map { " (\($0))" } ?? "")"))
        }
    }

    private func signInHint(for providerID: String) -> String {
        switch providerID {
        case "claude": return "Open Claude Code to sign in / refresh"
        case "codex":  return "Run `codex login` to sign in"
        default:       return "Sign in with the provider's own tool"
        }
    }

    private func installName(for providerID: String) -> String {
        switch providerID {
        case "claude": return "Claude Code"
        case "codex":  return "Codex CLI"
        default:       return providerID
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
    @objc private func showUsageBar() {
        Log(category: "menu").info("show usage bar requested",
                                   ["handler": onShowUsageBar == nil ? "missing" : "present"])
        onShowUsageBar?()
    }
    @objc private func showDiagnostics() { onShowDiagnostics?() }

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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Touch Bar Usage"
        alert.informativeText = """
        Claude Code and Codex usage, one tap away on your Touch Bar.

        An independent open-source project. Not affiliated with, endorsed by, \
        or sponsored by Anthropic or OpenAI.
        """
        alert.runModal()
    }

    @objc private func quit() { onQuit?() }
}

extension MenuBarController: NSMenuDelegate {
    /// Refresh the age lines in place.
    ///
    /// Deliberately **not** a full rebuild: calling `removeAllItems()` from
    /// `menuWillOpen` tears down the items macOS is in the middle of displaying,
    /// and clicks then land on items that no longer exist — the action never
    /// fires. Only existing titles are mutated here; structural changes happen on
    /// state updates and after the menu closes.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { refreshAgeLines() }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }
}
