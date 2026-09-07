import Foundation

/// What the Touch Bar is currently showing.
///
/// The product has two states, and this type is the authority on which one is
/// active. `normal` means macOS owns the Touch Bar and we contribute only the
/// small tray entry point — that is the resting state, and the reason brightness
/// and volume keep working.
public enum TouchBarPresentation: Equatable, Sendable {
    /// Native macOS Touch Bar. Only the compact tray item is installed.
    case normal
    /// Expanded dashboard showing every provider.
    case dashboard
    /// One provider's detail page, reached from the dashboard.
    case detail(providerID: String)

    public var isUsageModeOpen: Bool {
        switch self {
        case .normal:             return false
        case .dashboard, .detail: return true
        }
    }

    /// The provider whose detail page is open, if any.
    public var detailProviderID: String? {
        if case .detail(let id) = self { return id }
        return nil
    }
}

/// Aggregates every provider for the expanded dashboard and the tray glyph.
///
/// Provider-agnostic by construction: it holds an ordered list of entries and
/// never names a specific provider, so adding one is a matter of passing another
/// entry rather than editing this type.
public struct DashboardViewModel: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        public let providerID: String
        public let displayName: String
        public let compact: TouchBarViewModel
        public let state: ProviderState

        public init(providerID: String, displayName: String, state: ProviderState) {
            self.providerID = providerID
            self.displayName = displayName
            self.state = state
            self.compact = TouchBarViewModel.make(providerName: displayName, state: state)
        }

        /// Severity to colour this entry by, or nil when it has no numbers.
        public var severity: UsageSeverity? {
            state.snapshot.map { $0.headlineSeverity }
        }

        public func detail(now: Date = Date()) -> DetailViewModel {
            DetailViewModel.make(providerName: displayName, state: state, now: now)
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func entry(providerID: String) -> Entry? {
        entries.first { $0.providerID == providerID }
    }

    /// Worst severity across every provider that has numbers, for the tray glyph.
    /// Nil when nothing has loaded, so the tray shows a plain mark rather than
    /// implying "all good".
    public var worstSeverity: UsageSeverity? {
        entries.compactMap(\.severity).max { lhs, rhs in
            severityRank(lhs) < severityRank(rhs)
        }
    }

    /// True when any provider needs the user to act (sign in, install, failure),
    /// which the menu surfaces even though the tray glyph only tracks quota.
    public var hasActionableProblem: Bool {
        entries.contains { $0.state.isTerminalFailure }
    }

    private func severityRank(_ severity: UsageSeverity) -> Int {
        switch severity {
        case .normal:   return 0
        case .elevated: return 1
        case .warning:  return 2
        case .critical: return 3
        }
    }
}
