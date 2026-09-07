import Foundation
import XCTest
@testable import TouchBarUsageKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("missing fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }
}

extension Date {
    /// Fixed reference instant so tests never depend on wall-clock time.
    static let testNow = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
}

func makeSnapshot(
    short: Double? = 72,
    weekly: Double? = 43,
    fetchedAt: Date = .testNow
) -> UsageSnapshot {
    var windows: [UsageWindow] = []
    if let short {
        windows.append(UsageWindow(
            id: "five_hour", label: "5h", longLabel: "5h", usedPercent: short,
            resetAt: fetchedAt.addingTimeInterval(2 * 3600 + 13 * 60),
            duration: 5 * 3600, category: .short))
    }
    if let weekly {
        windows.append(UsageWindow(
            id: "seven_day", label: "W", longLabel: "Week", usedPercent: weekly,
            resetAt: fetchedAt.addingTimeInterval(2 * 86400),
            duration: 7 * 86400, category: .weekly))
    }
    return UsageSnapshot(providerID: "claude", windows: windows, fetchedAt: fetchedAt)
}
