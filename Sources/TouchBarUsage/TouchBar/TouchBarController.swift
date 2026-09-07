import AppKit
import TouchBarUsageKit

/// Drives the two-state Touch Bar experience.
///
/// **Normal mode** is the resting state: macOS keeps its own Touch Bar and this
/// app contributes only a small Control Strip entry point, so brightness, volume
/// and per-app controls behave exactly as they normally would.
///
/// **Usage mode** is entered by tapping that entry point (or from the menu bar)
/// and presents the expanded Claude + Codex dashboard. Once open it **stays
/// open** — there is no inactivity timeout — until the user closes it or the Mac
/// sleeps, at which point the bar goes straight back to macOS.
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

    /// Refreshes the countdown text while a detail page is visible. This is the
    /// **only** timer in the presentation layer — there is deliberately no
    /// inactivity timer, so nothing can close usage mode behind the user's back.
    private var tickTimer: Timer?

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
        dashboardView = view
        detailView = nil
        // Coming back from a detail page: nothing left to tick.
        stopTickTimer()

        if bridge.isPresentingUsageBar {
            bridge.updateUsageBar(view: view)
        } else {
            bridge.presentUsageBar(view: view)
        }
        presentation = .dashboard
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
        detailView = view
        dashboardView = nil

        bridge.updateUsageBar(view: view)
        presentation = .detail(providerID: providerID)
        startTickTimer()
    }

    /// Leaves usage mode and returns the Touch Bar to macOS immediately. The tray
    /// item stays, so the user can reopen with one tap.
    func closeUsageMode() {
        stopTickTimer()
        bridge.dismissUsageBar()
        dashboardView = nil
        detailView = nil
        presentation = .normal
        log.info("usage mode closed; native touch bar restored")
    }

    // MARK: - System sleep

    /// Sleep is the only non-user event that closes usage mode.
    ///
    /// A system-modal Touch Bar left presented across a sleep/wake cycle risks
    /// coming back as a stale bar the user cannot dismiss, so it is torn down
    /// while the machine is still awake enough for the private API call to land.
    /// The tray item is deliberately left installed — it is the entry point, and
    /// removing it would leave nothing to tap on wake.
    func handleSystemWillSleep() {
        guard presentation.isUsageModeOpen else { return }
        log.info("usage mode dismissed for system sleep")
        closeUsageMode()
    }

    /// Wake restores the resting state and nothing more.
    ///
    /// Usage mode is **never** reopened automatically: the user asked for it once,
    /// before a sleep, and silently restoring it would put a modal bar on screen
    /// they did not ask for now. They tap the badge again if they want it.
    func handleSystemDidWake() {
        // Re-assert the tray item: the Touch Bar agent can drop registrations
        // across a sleep cycle, and installing is idempotent.
        if TouchBarLifecycle.shouldReinstallTrayItemOnWake(
            isSupported: bridge.isTrayItemSupported,
            isInstalled: bridge.isTrayItemInstalled) {
            log.info("reinstalling tray item after wake")
            installTrayItem()
        }
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
