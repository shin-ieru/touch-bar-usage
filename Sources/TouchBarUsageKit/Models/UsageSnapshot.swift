import Foundation

/// A normalized, credential-free view of one provider's usage at a point in time.
/// This is the only usage type that is ever cached or rendered.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let providerID: String
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(providerID: String, windows: [UsageWindow], fetchedAt: Date) {
        self.providerID = providerID
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    /// The window the compact bar shows first. Chosen by category, never by
    /// JSON key order.
    public var shortWindow: UsageWindow? {
        windows.first { $0.category == .short }
    }

    /// The general weekly window — explicitly not a model-specific weekly cap.
    public var weeklyWindow: UsageWindow? {
        windows.first { $0.category == .weekly }
    }

    /// Per-model weekly caps, shown only in the detail view.
    public var modelSpecificWindows: [UsageWindow] {
        windows.filter { $0.category == .modelSpecific }
    }

    /// Worst severity across the two headline windows, used to colour the bar.
    public var headlineSeverity: UsageSeverity {
        let pct = [shortWindow?.usedPercent, weeklyWindow?.usedPercent]
            .compactMap { $0 }
            .max() ?? 0
        return UsageSeverity(usedPercent: pct)
    }

    public func isStale(now: Date = Date(), threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) > threshold
    }
}
