import Foundation

/// When usage mode may close.
///
/// Usage mode is **persistent**: once opened it stays open until the user closes
/// it, or the Mac sleeps. There is deliberately no inactivity timeout — an
/// earlier version dismissed after 12 seconds, which meant the bar vanished
/// while you were still reading a reset time.
///
/// The policy lives here, free of AppKit, so the transitions are unit tested
/// rather than only asserted in comments in the controller.
public enum TouchBarLifecycle {

    /// Sleep is the only non-user event that closes usage mode.
    ///
    /// A system-modal Touch Bar left presented across a sleep/wake cycle risks
    /// returning as a stale bar the user cannot dismiss, so it is torn down while
    /// the machine is still awake.
    public static func presentationAfterSleep(from current: TouchBarPresentation) -> TouchBarPresentation {
        .normal
    }

    /// Wake restores the resting state and nothing more.
    ///
    /// Usage mode is never reopened automatically: the request to open it was
    /// made before a sleep, and silently restoring it would put a modal bar on
    /// screen the user did not ask for now.
    public static func presentationAfterWake(from current: TouchBarPresentation) -> TouchBarPresentation {
        .normal
    }

    /// Whether the tray badge should be re-asserted on wake. Installing is
    /// idempotent, but the Touch Bar agent can drop registrations across a sleep
    /// cycle, so a missing item is reinstalled.
    public static func shouldReinstallTrayItemOnWake(isSupported: Bool, isInstalled: Bool) -> Bool {
        isSupported && !isInstalled
    }

    /// Whether anything other than the user or system sleep may close usage mode.
    ///
    /// Always false, and asserted in tests so a future timer cannot quietly
    /// reintroduce the behaviour that was removed.
    public static let hasInactivityTimeout = false
}
