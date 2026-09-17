import AppKit
import TouchBarUsageKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Log(category: "app")
    private var menuBar: MenuBarController!
    private var touchBar: TouchBarController!
    private var diagnosticsWindow: DiagnosticsWindowController?

    /// One coordinator per provider. `RefreshCoordinator` wraps a single provider
    /// deliberately: backoff and last-good-snapshot are per-provider, so one
    /// provider being rate limited or offline cannot stall the other.
    private var coordinators: [(provider: UsageProvider, coordinator: RefreshCoordinator)] = []
    private var states: [String: ProviderState] = [:]

    private let cache = CacheStore()
    private var refreshTimer: Timer?
    private var didTearDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background utility: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        let providers: [UsageProvider] = [
            ClaudeUsageProvider(),
            CodexUsageProvider(),
        ]
        for provider in providers {
            states[provider.id] = .loading
            coordinators.append((provider, RefreshCoordinator(provider: provider, cache: cache)))
        }

        menuBar = MenuBarController()
        menuBar.onRefresh = { [weak self] in self?.refreshAll(trigger: .manual) }
        menuBar.onShowUsageBar = { [weak self] in self?.touchBar.openUsageMode() }
        menuBar.onShowDiagnostics = { [weak self] in self?.showDiagnostics() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        touchBar = TouchBarController()
        touchBar.onUsageModeOpened = { [weak self] in self?.refreshAll(trigger: .manual) }
        let installed = touchBar.installTrayItem()
        menuBar.setTouchBarStatus(traySupported: touchBar.isTrayItemSupported,
                                  trayInstalled: installed,
                                  usageBarSupported: touchBar.isUsageBarSupported)
        if !installed {
            log.warning("tray item not installed; use the menu to open usage mode")
        }

        if let forced = DebugState.forcedStates() {
            log.warning("forced state active")
            states = forced
            publish()
            return
        }

        observeStates()
        startRefreshTimer()
        observeSleepAndWake()
        openUsageModeAtLaunchIfRequested()

        Task { [weak self] in
            guard let self else { return }
            for entry in coordinators {
                await entry.coordinator.primeFromCache()
            }
            await refreshAllAsync(trigger: .launch)
        }
    }

    // MARK: - State plumbing

    private func observeStates() {
        for entry in coordinators {
            let id = entry.provider.id
            Task { [weak self] in
                await entry.coordinator.addObserver { state in
                    Task { @MainActor [weak self] in
                        self?.states[id] = state
                        self?.publish()
                    }
                }
            }
        }
    }

    private func publish() {
        let model = DashboardViewModel(entries: coordinators.map { entry in
            DashboardViewModel.Entry(
                providerID: entry.provider.id,
                displayName: entry.provider.displayName,
                state: states[entry.provider.id] ?? .loading)
        })
        touchBar.update(model: model)
        menuBar.update(model: model)
    }

    /// Providers are refreshed independently and concurrently; one failing or
    /// hanging must not delay the other.
    private func refreshAll(trigger: RefreshCoordinator.Trigger) {
        Task { await refreshAllAsync(trigger: trigger) }
    }

    private func refreshAllAsync(trigger: RefreshCoordinator.Trigger) async {
        await withTaskGroup(of: Void.self) { group in
            for entry in coordinators {
                group.addTask { await entry.coordinator.refresh(trigger: trigger) }
            }
        }
    }

    /// One timer, coarse tolerance, so the app is effectively idle between ticks.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAll(trigger: .timer)
                for entry in self.coordinators {
                    await entry.coordinator.reevaluateStaleness()
                }
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Sleep is the only non-user event that closes usage mode; see
    /// `TouchBarController.handleSystemWillSleep`.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.touchBar?.handleSystemWillSleep() }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Restores the resting state only. Usage mode is never reopened
                // automatically — the user taps the badge if they want it back.
                self.touchBar?.handleSystemDidWake()
                self.refreshAll(trigger: .wake)
            }
        }
    }

    /// Development affordance: open usage mode shortly after launch so the
    /// presentation path can be checked on the physical bar independently of the
    /// menu that normally triggers it. It stays open like any other usage mode.
    private func openUsageModeAtLaunchIfRequested() {
        guard ProcessInfo.processInfo.environment["TBU_OPEN_USAGE_AT_LAUNCH"] == "1" else { return }
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.touchBar.openUsageMode() }
        }
        RunLoop.main.add(timer, forMode: .common)
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

        for entry in coordinators {
            let id = entry.provider.id
            entries.append(.init(label: "—", value: entry.provider.displayName))
            entries.append(.init(label: "\(entry.provider.displayName) state",
                                 value: (states[id] ?? .loading).diagnosticLabel))
            entries.append(.init(label: "\(entry.provider.displayName) mascot",
                                 value: await MainActor.run { MascotProvider.activeSource(for: id) }))
            entries.append(contentsOf: await entry.provider.diagnostics())
            if case .stale = states[id] {
                entries.append(.init(label: "\(entry.provider.displayName) displayed usage source", value: "stale cache"))
            }
            if let last = await entry.coordinator.lastSuccessfulFetch {
                entries.append(.init(label: "\(entry.provider.displayName) last refresh",
                                     value: ResetFormatter.age(since: last)))
            } else {
                entries.append(.init(label: "\(entry.provider.displayName) last refresh", value: "never"))
            }
        }

        entries.append(.init(label: "Launch at login", value: LoginItemService.statusDescription))
        entries.append(.init(label: "Telemetry", value: "none"))
        return entries
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        tearDown()
    }

    /// Idempotent: `applicationWillTerminate` and the signal handlers can both
    /// reach here, and tearing down twice must be harmless.
    func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        refreshTimer?.invalidate()
        touchBar?.teardown()
        CodexAppServerClient.shutdownShared()
        log.info("terminated cleanly")
    }
}

/// Development-only state pinning, driven by `TBU_FORCE_SEVERITY`.
///
/// Exists so the higher severity bands and the failure presentations can be
/// verified on the physical Touch Bar without waiting for real quota to move.
/// Percentages and mascot pose always agree, so a forced state is internally
/// consistent rather than a mascot disagreeing with the numbers beside it.
///
///     TBU_FORCE_SEVERITY=critical "dist/Touch Bar Usage.app/Contents/MacOS/TouchBarUsage"
///
/// Applies to every provider, plus `TBU_FORCE_CODEX` to force just Codex — which
/// is how the mixed "one provider fine, one signed out" layout is checked.
enum DebugState {
    static func forcedStates() -> [String: ProviderState]? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TBU_FORCE_SEVERITY"]?.lowercased() else { return nil }
        guard let claude = state(named: raw) else { return nil }

        let codexRaw = environment["TBU_FORCE_CODEX"]?.lowercased()
        let codex = codexRaw.flatMap { state(named: $0) } ?? claude
        return ["claude": claude, "codex": codex]
    }

    static func state(named raw: String) -> ProviderState? {
        switch raw {
        case "auth", "needsauthentication": return .needsAuthentication
        case "offline":                     return .offline
        case "ratelimited":                 return .rateLimited(retryAfter: 300)
        case "loading":                     return .loading
        case "notinstalled":                return .notInstalled
        case "failed":                      return .failed("forced")
        case "weeklyonly":                  return .ready(snapshot(short: nil, weekly: 31))
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

        let value = snapshot(short: percentages.short, weekly: percentages.weekly)
        return raw == "stale" ? .stale(value, reason: "forced") : .ready(value)
    }

    private static func snapshot(short: Double?, weekly: Double) -> UsageSnapshot {
        let now = Date()
        var windows: [UsageWindow] = []
        if let short {
            windows.append(UsageWindow(id: "five_hour", label: "5h", longLabel: "5h",
                                       usedPercent: short,
                                       resetAt: now.addingTimeInterval(8_000),
                                       duration: 5 * 3600, category: .short))
        }
        windows.append(UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                                   usedPercent: weekly,
                                   resetAt: now.addingTimeInterval(180_000),
                                   duration: 7 * 86_400, category: .weekly))
        return UsageSnapshot(providerID: "claude", windows: windows, fetchedAt: now)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.2"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "\(short) (\(build))"
    }
}

/// Best-effort hardware check. A Mac without a Touch Bar still runs the app;
/// it just reports the hardware as absent in Diagnostics.
enum TouchBarHardware {
    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: "/usr/libexec/TouchBarServer")
    }
    static var description: String { isPresent ? "detected" : "not detected" }
}
