import AppKit
import TouchBarUsageKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Log(category: "app")
    private var menuBar: MenuBarController!
    private var touchBar: TouchBarController!
    private var diagnosticsWindow: DiagnosticsWindowController?

    private let provider = ClaudeUsageProvider()
    private let cache = CacheStore()
    private var coordinator: RefreshCoordinator!

    private var refreshTimer: Timer?
    private var didTearDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        coordinator = RefreshCoordinator(provider: provider, cache: cache)

        menuBar = MenuBarController()
        menuBar.onRefresh = { [weak self] in self?.refresh(trigger: .manual) }
        menuBar.onToggleTouchBar = { [weak self] enabled in self?.setTouchBar(enabled: enabled) }
        menuBar.onShowDiagnostics = { [weak self] in self?.showDiagnostics() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        touchBar = TouchBarController()
        touchBar.onDetailShown = { [weak self] in self?.refresh(trigger: .manual) }
        let installed = touchBar.install()
        menuBar.setTouchBarSupported(touchBar.isSupported)
        if !installed {
            log.warning("running without touch bar presentation")
        }

        // Development affordance: pin the app to one severity band so the higher
        // bands can be checked on the physical bar without waiting for real
        // usage to climb. Unset in normal use, so it can never misreport.
        if let forced = DebugState.forcedState() {
            log.warning("forced state active", ["state": forced.diagnosticLabel])
            apply(forced)
            return
        }

        observeState()
        startRefreshTimer()
        observeWake()

        Task {
            // Show cached numbers instantly, marked stale, then refresh.
            await coordinator.primeFromCache()
            await coordinator.refresh(trigger: .launch)
        }
    }

    // MARK: - State plumbing

    private func observeState() {
        Task { [weak self] in
            guard let self else { return }
            await coordinator.addObserver { state in
                Task { @MainActor [weak self] in self?.apply(state) }
            }
        }
    }

    private func apply(_ state: ProviderState) {
        touchBar.update(state: state)
        menuBar.update(state: state)
    }

    private func refresh(trigger: RefreshCoordinator.Trigger) {
        Task { await coordinator.refresh(trigger: trigger) }
    }

    /// One timer, coarse tolerance, so the app is effectively idle between ticks.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval: TimeInterval = 300
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(trigger: .timer)
                // Age the snapshot locally even when the network is gone.
                await self?.coordinator.reevaluateStaleness()
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(trigger: .wake) }
        }
    }

    private func setTouchBar(enabled: Bool) {
        if enabled {
            touchBar.install()
            Task { [weak self] in
                guard let self else { return }
                let state = await coordinator.state
                await MainActor.run { self.touchBar.update(state: state) }
            }
        } else {
            touchBar.teardown()
        }
    }

    private func showDiagnostics() {
        Task { [weak self] in
            guard let self else { return }
            let report = await buildDiagnostics()
            await MainActor.run {
                if diagnosticsWindow == nil { diagnosticsWindow = DiagnosticsWindowController() }
                diagnosticsWindow?.show(report: report)
            }
        }
    }

    /// Presence and status only — never a token, credential blob, account
    /// identifier, or raw payload.
    private func buildDiagnostics() async -> [DiagnosticEntry] {
        var entries: [DiagnosticEntry] = []
        entries.append(.init(label: "App version", value: AppInfo.version))
        entries.append(.init(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString))
        entries.append(.init(label: "Touch Bar hardware", value: TouchBarHardware.description))
        entries.append(contentsOf: await MainActor.run { touchBar.diagnostics })
        entries.append(.init(label: "Touch Bar presentation",
                             value: await MainActor.run { menuBar.isTouchBarEnabled ? "on" : "off" }))
        entries.append(.init(label: "Mascot", value: await MainActor.run { MascotProvider.activeSource }))
        entries.append(contentsOf: await provider.diagnostics())

        let state = await coordinator.state
        entries.append(.init(label: "Current state", value: state.diagnosticLabel))
        if let last = await coordinator.lastSuccessfulFetch {
            entries.append(.init(label: "Last successful refresh", value: ResetFormatter.age(since: last)))
        } else {
            entries.append(.init(label: "Last successful refresh", value: "never"))
        }
        entries.append(.init(label: "Refresh interval",
                             value: "\(Int(await coordinator.refreshInterval / 60)) min"))
        entries.append(.init(label: "Launch at login", value: LoginItemService.statusDescription))
        entries.append(.init(label: "Telemetry", value: "none"))
        return entries
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        tearDown()
    }

    /// Idempotent: `applicationWillTerminate` and the signal handlers can both
    /// reach here, and removing the tray item twice must be harmless.
    func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        refreshTimer?.invalidate()
        touchBar?.teardown()
        log.info("terminated cleanly")
    }
}

/// Development-only state pinning, driven by `TBU_FORCE_SEVERITY`.
///
/// Exists so the `warning` and `critical` presentations — including Clawd's
/// poses — can be verified on the physical Touch Bar without waiting for real
/// quota to reach 85% or 95%. Percentages and pose always agree, so the forced
/// state is internally consistent rather than a mascot lying about the numbers.
///
/// When the variable is unset (the normal case) this returns nil and the app
/// behaves exactly as it otherwise would.
///
///     TBU_FORCE_SEVERITY=critical "dist/Touch Bar Usage.app/Contents/MacOS/TouchBarUsage"
enum DebugState {
    static func forcedState() -> ProviderState? {
        guard let raw = ProcessInfo.processInfo.environment["TBU_FORCE_SEVERITY"]?.lowercased() else {
            return nil
        }
        // Non-numeric states are reachable too, so their layouts can be checked.
        switch raw {
        case "auth", "needsauthentication": return .needsAuthentication
        case "offline":                     return .offline
        case "ratelimited":                 return .rateLimited(retryAfter: 300)
        case "loading":                     return .loading
        default: break
        }

        let percentages: (short: Double, weekly: Double)
        switch raw {
        case "normal":   percentages = (32, 18)
        case "elevated": percentages = (72, 43)
        case "warning":  percentages = (88, 61)
        case "critical": percentages = (97, 90)
        case "stale":    percentages = (72, 43)
        default:         return nil
        }

        let now = Date()
        let snapshot = UsageSnapshot(
            providerID: "claude",
            windows: [
                UsageWindow(id: "five_hour", label: "5h", longLabel: "5h",
                            usedPercent: percentages.short,
                            resetAt: now.addingTimeInterval(8_000),
                            duration: 5 * 3600, category: .short),
                UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                            usedPercent: percentages.weekly,
                            resetAt: now.addingTimeInterval(180_000),
                            duration: 7 * 86_400, category: .weekly),
            ],
            fetchedAt: now)

        return raw == "stale" ? .stale(snapshot, reason: "forced") : .ready(snapshot)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "\(short) (\(build))"
    }
}

/// Best-effort hardware check. A Mac without a Touch Bar still runs the app;
/// it just reports the hardware as absent in Diagnostics.
enum TouchBarHardware {
    static var isPresent: Bool {
        // TouchBarServer only runs on machines with the physical bar.
        !runningProcessPaths().filter { $0.hasSuffix("/TouchBarServer") }.isEmpty
    }

    static var description: String { isPresent ? "detected" : "not detected" }

    private static func runningProcessPaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.path }
            + [FileManager.default.fileExists(atPath: "/usr/libexec/TouchBarServer")
               ? "/usr/libexec/TouchBarServer" : ""]
    }
}
