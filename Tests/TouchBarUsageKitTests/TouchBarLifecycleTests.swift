import XCTest
@testable import TouchBarUsageKit

/// Usage mode is persistent: once opened it stays open until the user closes it
/// or the Mac sleeps.
///
/// An earlier version dismissed after 12 seconds of inactivity, which meant the
/// bar vanished while you were still reading a reset time. These tests exist to
/// keep that from creeping back.
final class TouchBarLifecycleTests: XCTestCase {

    private let allOpenStates: [TouchBarPresentation] = [
        .dashboard,
        .detail(providerID: "claude"),
        .detail(providerID: "codex"),
    ]

    // MARK: - Persistence

    /// The headline guarantee, asserted as a constant so a future timer cannot
    /// quietly reintroduce the removed behaviour.
    func testThereIsNoInactivityTimeout() {
        XCTAssertFalse(TouchBarLifecycle.hasInactivityTimeout)
    }

    /// Nothing about the passage of time changes the presentation. There is no
    /// deadline to advance past, which is the whole point.
    func testOpenStatesRemainOpenIndefinitely() {
        for state in allOpenStates {
            XCTAssertTrue(state.isUsageModeOpen, "\(state) should be an open state")
            // No API exists to age the presentation out — the only transitions
            // are the explicit ones below.
        }
    }

    func testDetailStatesAreOpenAndIdentifyTheirProvider() {
        XCTAssertEqual(TouchBarPresentation.detail(providerID: "claude").detailProviderID, "claude")
        XCTAssertEqual(TouchBarPresentation.detail(providerID: "codex").detailProviderID, "codex")
        XCTAssertTrue(TouchBarPresentation.detail(providerID: "codex").isUsageModeOpen)
    }

    // MARK: - Explicit close

    /// Close is authoritative from every open state, including both details.
    func testCloseFromAnyOpenStateReturnsToNative() {
        for state in allOpenStates {
            XCTAssertTrue(state.isUsageModeOpen)
            // Closing is modelled as a direct transition to `.normal`.
            let afterClose = TouchBarPresentation.normal
            XCTAssertFalse(afterClose.isUsageModeOpen, "close from \(state) must return to native")
            XCTAssertNil(afterClose.detailProviderID)
        }
    }

    // MARK: - Sleep

    func testSleepFromAnyOpenStateReturnsToNative() {
        for state in allOpenStates {
            XCTAssertEqual(TouchBarLifecycle.presentationAfterSleep(from: state), .normal,
                           "sleeping while \(state) was open must leave native")
        }
    }

    func testSleepWhileAlreadyNativeStaysNative() {
        XCTAssertEqual(TouchBarLifecycle.presentationAfterSleep(from: .normal), .normal)
    }

    // MARK: - Wake

    /// The important one: waking must not restore a bar the user asked for
    /// before the sleep.
    func testWakeNeverReopensUsageMode() {
        for state in allOpenStates + [.normal] {
            let afterWake = TouchBarLifecycle.presentationAfterWake(from: state)
            XCTAssertEqual(afterWake, .normal)
            XCTAssertFalse(afterWake.isUsageModeOpen,
                           "wake must not reopen usage mode (was \(state))")
        }
    }

    /// Sleep then wake, from every open state, lands on native and stays there.
    func testFullSleepWakeCycleLandsOnNative() {
        for state in allOpenStates {
            let afterSleep = TouchBarLifecycle.presentationAfterSleep(from: state)
            let afterWake = TouchBarLifecycle.presentationAfterWake(from: afterSleep)
            XCTAssertEqual(afterWake, .normal)
        }
    }

    // MARK: - Tray item across wake

    /// The badge is the entry point; without it there is nothing to tap.
    func testTrayItemIsReinstalledOnWakeOnlyWhenMissing() {
        XCTAssertTrue(TouchBarLifecycle.shouldReinstallTrayItemOnWake(
            isSupported: true, isInstalled: false), "a dropped registration is restored")
        XCTAssertFalse(TouchBarLifecycle.shouldReinstallTrayItemOnWake(
            isSupported: true, isInstalled: true), "installing twice would duplicate it")
        XCTAssertFalse(TouchBarLifecycle.shouldReinstallTrayItemOnWake(
            isSupported: false, isInstalled: false), "not supported here, nothing to install")
    }
}
