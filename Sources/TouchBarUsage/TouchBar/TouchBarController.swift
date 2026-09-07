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

    /// Apple's Control Strip item would be the coexisting path, but it does not
    /// render on macOS 26.6.2 (see docs/touchbar-research.md). Opt in with
    /// `TBU_TOUCHBAR_STRATEGY=controlStripItem` to re-measure on a future release.
    static var usesControlStripItem: Bool {
        ProcessInfo.processInfo.environment["TBU_TOUCHBAR_STRATEGY"] == "controlStripItem"
    }

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
        let surface = CompactSurfaceView(hosting: view)
        // Prefer Apple's own coexistence mechanism; fall back to the modal bar.
        if Self.usesControlStripItem, bridge.presentControlStripItem(view: surface) {
            return true
        }
        return bridge.presentAlongsideControlStrip(view: surface)
    }

    func update(state: ProviderState) {
        self.state = state
        compactView?.apply(TouchBarViewModel.make(state: state))
        if bridge.isPresentingDetail {
            refreshDetail()
        }
    }

    // MARK: - Detail presentation

    private func showDetail() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.detailItemIdentifier]
        detailBar = bar
        bridge.presentDetail(bar)
        startDetailTimer()
        onDetailShown?()
    }

    private func hideDetail() {
        stopDetailTimer()
        // Dismissing the detail bar also re-presents the compact widget beside
        // the Control Strip; the bridge owns that sequencing.
        bridge.dismissDetail()
        detailBar = nil
        detailView = nil
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

/// Fixed-size surface hosting the compact widget.
///
/// A system-modal bar presented at `placement: 0` needs its item view to carry a
/// concrete frame — an Auto Layout-only view collapses and is never drawn. The
/// surface is sized explicitly and the widget is pinned to its leading edge, so
/// Apple's Control Strip keeps the right-hand side of the bar.
final class CompactSurfaceView: NSView {
    /// Width of the custom region. Wide enough for the widget plus headroom,
    /// while leaving the Control Strip its own space on the right.
    static let surfaceWidth: CGFloat = 420
    static let surfaceHeight: CGFloat = 30

    init(hosting content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.surfaceWidth, height: Self.surfaceHeight))
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.surfaceWidth, height: Self.surfaceHeight)
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
