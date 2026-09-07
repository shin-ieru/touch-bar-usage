import XCTest
@testable import TouchBarUsageKit

/// The tray badge fallback order.
///
/// The point of these is the last one: text must never be the default when a
/// graphic is available, because the tray item is the app's only Touch Bar
/// identity and "AI" says nothing about which providers it covers.
final class TrayBadgeResolutionTests: XCTestCase {

    func testLocalOverrideWinsOverEverything() {
        XCTAssertEqual(
            TrayBadgeResolution.source(hasLocalOverride: true, canCompose: true),
            .localOverride)
        XCTAssertEqual(
            TrayBadgeResolution.source(hasLocalOverride: true, canCompose: false),
            .localOverride)
    }

    func testComposedBadgeIsPreferredWhenBothMarksResolve() {
        XCTAssertEqual(
            TrayBadgeResolution.source(hasLocalOverride: false, canCompose: true),
            .composed)
    }

    /// A clean checkout with no local or generated assets still gets a graphic.
    func testFallsBackToTheDrawnGraphicWhenNothingCanBeComposed() {
        XCTAssertEqual(
            TrayBadgeResolution.source(hasLocalOverride: false, canCompose: false),
            .fallbackGraphic)
    }

    /// Text is reachable only if even the code-drawn badge fails, which in
    /// practice it cannot.
    func testTextIsTheLastResortOnly() {
        XCTAssertEqual(
            TrayBadgeResolution.source(hasLocalOverride: false,
                                       canCompose: false,
                                       canDrawFallback: false),
            .text)
    }

    /// Guards the regression this patch exists to prevent.
    func testEveryTierExceptTheLastResortIsGraphic() {
        for hasOverride in [true, false] {
            for canCompose in [true, false] {
                let source = TrayBadgeResolution.source(hasLocalOverride: hasOverride,
                                                        canCompose: canCompose)
                XCTAssertTrue(source.isGraphic,
                              "a graphic badge must always be available (override: \(hasOverride), compose: \(canCompose))")
                XCTAssertNotEqual(source, .text)
            }
        }
    }

    func testDiagnosticDescriptionsAreDistinctAndNonEmpty() {
        let descriptions = TrayBadgeSource.allCases.map(\.diagnosticDescription)
        XCTAssertEqual(Set(descriptions).count, TrayBadgeSource.allCases.count)
        XCTAssertFalse(descriptions.contains { $0.isEmpty })
    }
}
