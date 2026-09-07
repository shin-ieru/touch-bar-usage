import AppKit
import TouchBarUsageKit

/// Drives the two-state Touch Bar experience.
///
/// **Normal mode** is the resting state: macOS keeps its own Touch Bar and this
/// app contributes only a small Control Strip entry point, so brightness, volume
/// and per-app controls behave exactly as they normally would.
///
/// **Usage mode** is entered by tapping that entry point (or from the menu bar)
/// and presents the expanded Claude + Codex dashboard. It is intentionally
/// temporary: closing it, or letting it auto-dismiss, hands the bar straight back
/// to macOS.
///
/// Phase 1 kept a widget permanently presented over the whole strip. That was
/// abandoned because a system-modal bar is inherently full-width, so it
/// permanently displaced Apple's controls. See docs/touchbar-research.md.
@MainActor
final class TouchBarController: NSObject {

    private let bridge: SystemModalTouchBarBridge
    private let log = Log(category: "touchbar")

    private var trayView: UsageTrayView?
    private var dashboardView: UsageDashboardView?
    private var detailView: ProviderDetailView?

    private var model = DashboardViewModel(entries: [])
    private(set) var presentation: TouchBarPresentation = .normal

    /// Auto-dismiss: usage mode should not sit open indefinitely.
    private var dismissTimer: Timer?
    /// Refreshes the countdown text while a detail page is visible.
    private var tickTimer: Timer?

    /// Chosen after physical testing: long enough to read both providers and tap
    /// into a detail page, short enough that a stray tap does not strand the bar.
    static let autoDismissInterval: TimeInterval = 12

    /// Called when usage mode opens, so the app can refresh opportunistically.
    var onUsageModeOpened: (() -> Void)?

    private static let trayIdentifier = "com.gabrielanyog.touchbarusage.tray"

    var isTrayItemSupported: Bool { bridge.isTrayItemSupported }
    var isUsageBarSupported: Bool { bridge.isUsageBarSupported }
    var isTrayItemInstalled: Bool { bridge.isTrayItemInstalled }

    override init() {
        bridge = SystemModalTouchBarBridge(identifier: Self.trayIdentifier)
        super.init()
    }

    // MARK: - Normal mode

    /// Installs the small persistent entry point. Returns false when the private
    /// API is unavailable, in which case the app runs menu-bar-only rather than
    /// showing a broken bar.
    @discardableResult
    func installTrayItem() -> Bool {
        guard bridge.isTrayItemSupported else {
            log.warning("tray item unsupported; menu bar only")
            return false
        }
        let view = UsageTrayView(severity: model.worstSeverity)
        view.onTap = { [weak self] in self?.openUsageMode() }
        trayView = view
        return bridge.installUsageTrayItem(view: view)
    }

    func removeTrayItem() {
        bridge.removeUsageTrayItem()
        trayView = nil
    }

    // MARK: - State

    func update(model: DashboardViewModel) {
        self.model = model
        trayView?.apply(severity: model.worstSeverity)

        switch presentation {
        case .normal:
            break
        case .dashboard:
            dashboardView?.apply(model)
        case .detail(let providerID):
            if let entry = model.entry(providerID: providerID) {
                detailView?.apply(entry.detail())
            }
        }
    }

    // MARK: - Usage mode

    /// Opens the expanded dashboard. Also the target of the menu bar's
    /// "Show Usage on Touch Bar", which is the fallback if the tray item is not
    /// rendered on a given macOS version.
    func openUsageMode() {
        guard bridge.isUsageBarSupported else {
            log.warning("usage bar unsupported")
            return
        }
        let view = UsageDashboardView(model: model)
        view.onSelectProvider = { [weak self] id in self?.showDetail(providerID: id) }
        view.onClose = { [weak self] in self?.closeUsageMode() }
        view.onInteraction = { [weak self] in self?.restartDismissTimer() }
        dashboardView = view
        detailView = nil

        if bridge.isPresentingUsageBar {
            bridge.updateUsageBar(view: view)
        } else {
            bridge.presentUsageBar(view: view)
        }
        presentation = .dashboard
        restartDismissTimer()
        onUsageModeOpened?()
    }

    private func showDetail(providerID: String) {
        guard let entry = model.entry(providerID: providerID) else { return }
        let view = ProviderDetailView(
            detail: entry.detail(),
            mascot: MascotProvider.mascot(for: providerID, height: 30,
                                          severity: entry.severity ?? .normal))
        view.onBack = { [weak self] in self?.openUsageMode() }
        view.onClose = { [weak self] in self?.closeUsageMode() }
        view.onInteraction = { [weak self] in self?.restartDismissTimer() }
        detailView = view
        dashboardView = nil

        bridge.updateUsageBar(view: view)
        presentation = .detail(providerID: providerID)
        restartDismissTimer()
        startTickTimer()
    }

    /// Leaves usage mode and returns the Touch Bar to macOS. The tray item stays.
    func closeUsageMode() {
        stopDismissTimer()
        stopTickTimer()
        bridge.dismissUsageBar()
        dashboardView = nil
        detailView = nil
        presentation = .normal
        log.info("usage mode closed; native touch bar restored")
    }

    // MARK: - Auto-dismiss

    /// Restarted by every interaction, so the bar never closes under the user's
    /// finger. Only usage mode is timed; normal mode has nothing to dismiss.
    private func restartDismissTimer() {
        stopDismissTimer()
        let timer = Timer(timeInterval: Self.autoDismissInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoDismiss() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func autoDismiss() {
        guard presentation.isUsageModeOpen else { return }
        log.info("usage mode auto-dismissed")
        closeUsageMode()
    }

    private func stopDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// Countdown text ticks locally from the cached `resetAt`; it never triggers
    /// a network refresh, and only runs while a detail page is on screen.
    private func startTickTimer() {
        stopTickTimer()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .detail(let id) = self.presentation,
                      let entry = self.model.entry(providerID: id) else { return }
                self.detailView?.apply(entry.detail())
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Teardown

    func teardown() {
        stopDismissTimer()
        stopTickTimer()
        bridge.teardown()
        trayView = nil
        dashboardView = nil
        detailView = nil
        presentation = .normal
    }

    var diagnostics: [DiagnosticEntry] {
        var entries = SystemModalTouchBarBridge.availabilityReport
        entries.append(.init(label: "Touch Bar tray item",
                             value: bridge.isTrayItemInstalled ? "installed" : "not installed"))
        entries.append(.init(label: "Tray badge",
                             value: CombinedTrayBadgeResolver.activeSource.diagnosticDescription))
        entries.append(.init(label: "Touch Bar mode",
                             value: presentation.isUsageModeOpen ? "usage mode" : "normal (native)"))
        return entries
    }
}
