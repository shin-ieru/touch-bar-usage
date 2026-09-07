import AppKit
import TouchBarUsageKit

/// Development-only renderer: draws each Touch Bar state to a PNG so UI work
/// does not require repeatedly rebuilding and squinting at the physical bar.
///
/// Not part of the runtime path — it runs only via `--render-previews` and the
/// app exits immediately afterwards.
@MainActor
enum PreviewRenderer {

    /// The states worth eyeballing, in the order they are written out.
    static var scenarios: [(name: String, state: ProviderState)] {
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
        return [
            ("normal",        .ready(snapshot(32, 18))),
            ("elevated",      .ready(snapshot(72, 43))),
            ("warning",       .ready(snapshot(88, 61))),
            ("critical",      .ready(snapshot(97, 90))),
            ("stale",         .stale(snapshot(72, 43), reason: "offline")),
            ("offline",       .offline),
            ("auth-required", .needsAuthentication),
            ("loading",       .loading),
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

        for scenario in scenarios {
            let view = ClaudeCompactView(viewModel: TouchBarViewModel.make(state: scenario.state))
            write(view: view, size: view.intrinsicContentSize,
                  to: directory.appendingPathComponent("compact-\(scenario.name).png"))
        }

        // One detail render is enough to check the expanded layout.
        // The detail bar has no intrinsic width; the Touch Bar gives it the
        // full strip, so render it at a representative width.
        let detail = ClaudeDetailView(detail: DetailViewModel.make(state: scenarios[1].state))
        write(view: detail, size: NSSize(width: 680, height: 30),
              to: directory.appendingPathComponent("detail-elevated.png"))

        FileHandle.standardOutput.write(
            Data("Rendered \(scenarios.count + 1) previews to \(directory.path)\n".utf8))
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
