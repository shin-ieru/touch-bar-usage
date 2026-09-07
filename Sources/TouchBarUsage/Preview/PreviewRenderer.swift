import AppKit
import TouchBarUsageKit

/// Development-only renderer: draws each Touch Bar state to a PNG so UI work
/// does not require repeatedly rebuilding and squinting at the physical bar.
///
/// Not part of the runtime path — it runs only via `--render-previews` and the
/// app exits immediately afterwards.
@MainActor
enum PreviewRenderer {

    /// The states worth eyeballing, in the order they are written out. Each
    /// carries a state per provider so the mixed cases are covered too.
    static var scenarios: [(name: String, state: ProviderState, codexState: ProviderState)] {
        let now = Date()
        func snapshot(_ short: Double, _ weekly: Double) -> UsageSnapshot {
            UsageSnapshot(
                providerID: "claude",
                windows: [
                    UsageWindow(id: "five_hour", label: "5h", longLabel: "5h",
                                usedPercent: short, resetAt: now.addingTimeInterval(8_000),
                                duration: 5 * 3600, category: .short),
                    UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                                usedPercent: weekly, resetAt: now.addingTimeInterval(180_000),
                                duration: 7 * 86_400, category: .weekly),
                ],
                fetchedAt: now)
        }
        /// Codex reporting only a weekly window — the case that must never be
        /// padded out to a fabricated 0% five-hour figure.
        let weeklyOnly = UsageSnapshot(
            providerID: "codex",
            windows: [UsageWindow(id: "seven_day", label: "W", longLabel: "Week",
                                  usedPercent: 31, resetAt: now.addingTimeInterval(200_000),
                                  duration: 7 * 86_400, category: .weekly)],
            fetchedAt: now)

        return [
            ("normal",        .ready(snapshot(32, 18)),  .ready(snapshot(41, 22))),
            ("elevated",      .ready(snapshot(72, 43)),  .ready(snapshot(84, 51))),
            ("warning",       .ready(snapshot(88, 61)),  .ready(snapshot(90, 55))),
            ("critical",      .ready(snapshot(97, 90)),  .ready(snapshot(100, 19))),
            ("stale",         .stale(snapshot(72, 43), reason: "offline"), .ready(snapshot(60, 30))),
            ("offline",       .offline,                  .offline),
            ("auth-required", .needsAuthentication,      .needsAuthentication),
            ("loading",       .loading,                  .loading),
            // Failure isolation: one provider healthy, the other not.
            ("mixed",         .ready(snapshot(72, 43)),  .needsAuthentication),
            ("codex-missing", .ready(snapshot(72, 43)),  .notInstalled),
            ("codex-weekly-only", .ready(snapshot(72, 43)), .ready(weeklyOnly)),
        ]
    }

    /// Returns true when the argument was present and rendering ran.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-previews") else { return false }
        let directory = index + 1 < arguments.count ? arguments[index + 1] : "PreviewOutput"
        render(into: URL(fileURLWithPath: directory))
        return true
    }

    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var count = 0

        // Normal mode: the small Control Strip entry point, at each severity.
        //
        // Rendered in the light appearance, which inverts what the hardware does
        // — the Touch Bar is always dark and template artwork tints to near-white
        // there. These previews are for checking composition and fit; whether the
        // mark reads as a blob on OLED black can only be settled on the device.
        for (name, severity) in [("normal", UsageSeverity.normal), ("elevated", .elevated),
                                 ("warning", .warning), ("critical", .critical),
                                 ("loading", nil)] as [(String, UsageSeverity?)] {
            let tray = UsageTrayView(severity: severity)
            write(view: tray, size: tray.frame.size,
                  to: directory.appendingPathComponent("tray-\(name).png"))
            count += 1
        }

        // Usage mode: the expanded dual-provider dashboard in each state.
        for scenario in scenarios {
            let model = DashboardViewModel(entries: [
                .init(providerID: "claude", displayName: "Claude", state: scenario.state),
                .init(providerID: "codex", displayName: "Codex", state: scenario.codexState),
            ])
            let dashboard = UsageDashboardView(model: model)
            write(view: dashboard, size: NSSize(width: 760, height: 30),
                  to: directory.appendingPathComponent("dashboard-\(scenario.name).png"))
            count += 1
        }

        // A provider detail page, including the Back and Close controls.
        let detailModel = DashboardViewModel(entries: [
            .init(providerID: "claude", displayName: "Claude", state: scenarios[1].state),
        ])
        if let entry = detailModel.entry(providerID: "claude") {
            let detail = ProviderDetailView(
                detail: entry.detail(),
                mascot: MascotProvider.mascot(for: "claude", height: 30, severity: .elevated))
            write(view: detail, size: NSSize(width: 820, height: 30),
                  to: directory.appendingPathComponent("detail-claude.png"))
            count += 1
        }

        FileHandle.standardOutput.write(
            Data("Rendered \(count) previews to \(directory.path)\n".utf8))
    }

    private static func write(view: NSView, size: NSSize, to url: URL) {
        // `noIntrinsicMetric` is -1, not zero, so guard on a positive size.
        let width = size.width > 0 ? size.width : 200
        let height = size.height > 0 ? size.height : 30
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
