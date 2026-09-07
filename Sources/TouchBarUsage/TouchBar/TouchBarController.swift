import AppKit
import TouchBarUsageKit

/// Owns the Touch Bar presentation for one provider.
///
/// Phase 1 renders a single provider. The controller talks only to
/// `TouchBarViewModel` / `DetailViewModel`, so adding a second provider later is
/// a layout change here, not a rewrite (see docs/codex-handoff.md).
@MainActor
final class TouchBarController: NSObject {

    private let bridge: SystemModalTouchBarBridge
    private let log = Log(category: "touchbar")

    private var compactView: ClaudeCompactView?
    private var detailBar: NSTouchBar?
    private var detailView: ClaudeDetailView?

    private var state: ProviderState = .loading
    /// Refreshes only the countdown text, and only while the detail bar is up.
    private var detailTimer: Timer?

    /// Called when the user taps the widget, so the app can refresh opportunistically.
    var onDetailShown: (() -> Void)?

    private static let itemIdentifier = "com.gabrielanyog.touchbarusage.claude"
    private static let detailItemIdentifier = NSTouchBarItem.Identifier("com.gabrielanyog.touchbarusage.claude.detail")

    var isSupported: Bool { bridge.isSupported }

    override init() {
        bridge = SystemModalTouchBarBridge(identifier: Self.itemIdentifier)
        super.init()
    }

    /// Installs the Control Strip item. Returns false when private API is missing,
    /// in which case the app stays menu-bar-only rather than showing a broken bar.
    @discardableResult
    func install() -> Bool {
        guard bridge.isSupported else {
            log.warning("touch bar unsupported; running menu bar only")
            return false
        }
        let view = ClaudeCompactView(viewModel: TouchBarViewModel.make(state: state))
        view.onTap = { [weak self] in self?.showDetail() }
        compactView = view
        return bridge.present(view: view)
    }

    func update(state: ProviderState) {
        self.state = state
        compactView?.apply(TouchBarViewModel.make(state: state))
        if bridge.isPresentingModal {
            refreshDetail()
        }
    }

    // MARK: - Detail presentation

    private func showDetail() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.detailItemIdentifier]
        detailBar = bar
        bridge.presentModal(bar)
        startDetailTimer()
        onDetailShown?()
    }

    private func hideDetail() {
        stopDetailTimer()
        bridge.dismissModal()
        detailBar = nil
        detailView = nil
        // Under the persistent-modal strategy the compact widget *is* a modal
        // bar, so dismissing the detail bar would otherwise leave nothing.
        bridge.restoreCompactPresentation()
    }

    private func refreshDetail() {
        detailView?.apply(DetailViewModel.make(state: state))
    }

    /// The countdown ticks locally from the cached `resetAt`; it never triggers a
    /// network refresh, and it only runs while the detail bar is on screen.
    private func startDetailTimer() {
        stopDetailTimer()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDetail() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
    }

    private func stopDetailTimer() {
        detailTimer?.invalidate()
        detailTimer = nil
    }

    // MARK: - Teardown

    /// Removes the Control Strip item so the Touch Bar returns to normal and a
    /// relaunch does not leave a duplicate behind.
    func teardown() {
        stopDetailTimer()
        bridge.dismiss()
        compactView = nil
        detailBar = nil
        detailView = nil
    }

    var diagnostics: [DiagnosticEntry] {
        SystemModalTouchBarBridge.availabilityReport
    }
}

extension TouchBarController: NSTouchBarDelegate {
    nonisolated func touchBar(_ touchBar: NSTouchBar,
                              makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        MainActor.assumeIsolated {
            guard identifier == Self.detailItemIdentifier else { return nil }
            let view = ClaudeDetailView(detail: DetailViewModel.make(state: state))
            view.onDone = { [weak self] in self?.hideDetail() }
            detailView = view
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = view
            return item
        }
    }
}
