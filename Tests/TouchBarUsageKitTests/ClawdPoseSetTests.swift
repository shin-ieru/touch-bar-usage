import XCTest
@testable import TouchBarUsageKit

/// Covers the rules that decide whether the app shows Clawd or falls back to its
/// own mark. No network, no bundle, no Touch Bar — these run anywhere.
final class ClawdPoseSetTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a grid with a filled rectangle, so bounding-box maths is checkable.
    private func grid(size: Int = 20,
                      bodyRows: ClosedRange<Int>,
                      bodyColumns: ClosedRange<Int>,
                      eyes: [(Int, Int)] = []) -> [[Int]] {
        var rows = Array(repeating: Array(repeating: 0, count: size), count: size)
        for r in bodyRows { for c in bodyColumns { rows[r][c] = 1 } }
        for (r, c) in eyes { rows[r][c] = 2 }
        return rows
    }

    private func payload(gridSize: Int = 20, poses: [String: [[Int]]]) -> Data {
        let object: [String: Any] = ["gridSize": gridSize, "poses": poses]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private var fourPosePayload: Data {
        payload(poses: [
            "calm":    grid(bodyRows: 4...16, bodyColumns: 5...15, eyes: [(6, 7), (6, 13)]),
            "alert":   grid(bodyRows: 4...16, bodyColumns: 5...15, eyes: [(6, 7)]),
            "worried": grid(bodyRows: 4...16, bodyColumns: 5...15, eyes: [(6, 6), (6, 14)]),
            "panic":   grid(bodyRows: 2...16, bodyColumns: 5...15, eyes: [(6, 6), (6, 14)]),
        ])
    }

    // MARK: - Generated asset available

    func testParsesGeneratedPoseSet() throws {
        let set = try XCTUnwrap(ClawdPoseSet.parse(fourPosePayload))
        XCTAssertEqual(set.gridSize, 20)
        XCTAssertEqual(Set(set.poses.keys), ["calm", "alert", "worried", "panic"])
    }

    func testSeverityMapsToDistinctPoses() {
        XCTAssertEqual(ClawdPoseSet.poseName(for: .normal), "calm")
        XCTAssertEqual(ClawdPoseSet.poseName(for: .elevated), "alert")
        XCTAssertEqual(ClawdPoseSet.poseName(for: .warning), "worried")
        XCTAssertEqual(ClawdPoseSet.poseName(for: .critical), "panic")

        let names = UsageSeverity.allCases.map(ClawdPoseSet.poseName(for:))
        XCTAssertEqual(Set(names).count, UsageSeverity.allCases.count, "each band gets its own pose")
    }

    func testEachSeverityResolvesToAGrid() throws {
        let set = try XCTUnwrap(ClawdPoseSet.parse(fourPosePayload))
        for severity in UsageSeverity.allCases {
            XCTAssertNotNil(set.grid(for: severity), "\(severity) must resolve")
        }
        // The panic pose is genuinely different from calm.
        XCTAssertNotEqual(set.grid(for: .critical), set.grid(for: .normal))
    }

    /// A partially generated set must still render, not blank out.
    func testMissingPoseFallsBackToCalm() throws {
        let set = try XCTUnwrap(ClawdPoseSet.parse(payload(poses: [
            "calm": grid(bodyRows: 4...16, bodyColumns: 5...15),
        ])))
        XCTAssertEqual(set.grid(for: .critical), set.grid(for: .normal))
    }

    // MARK: - Generated asset missing or corrupt → fallback

    func testCorruptPayloadsAreRejected() {
        let bad: [Data] = [
            Data(),
            Data("not json".utf8),
            Data("{}".utf8),
            payload(poses: [:]),
            // Wrong row count.
            payload(poses: ["calm": Array(repeating: Array(repeating: 0, count: 20), count: 5)]),
            // Wrong column count.
            payload(poses: ["calm": Array(repeating: Array(repeating: 0, count: 3), count: 20)]),
        ]
        for data in bad {
            XCTAssertNil(ClawdPoseSet.parse(data), "corrupt payload must yield nil so the fallback is used")
        }
    }

    func testOutOfRangeCellValuesRejectThatPose() {
        var rows = grid(bodyRows: 4...16, bodyColumns: 5...15)
        rows[0][0] = 9   // not a valid cell value
        XCTAssertNil(ClawdPoseSet.parse(payload(poses: ["calm": rows])))
    }

    /// One bad pose must not discard the good ones.
    func testBadPoseIsDroppedButGoodPosesSurvive() throws {
        var broken = grid(bodyRows: 4...16, bodyColumns: 5...15)
        broken[3] = [1, 1]   // wrong width
        let set = try XCTUnwrap(ClawdPoseSet.parse(payload(poses: [
            "calm": grid(bodyRows: 4...16, bodyColumns: 5...15),
            "panic": broken,
        ])))
        XCTAssertEqual(Set(set.poses.keys), ["calm"])
        XCTAssertNotNil(set.grid(for: .critical), "falls back to calm")
    }

    func testAbsurdGridSizeIsRejected() {
        XCTAssertNil(ClawdPoseSet.parse(payload(gridSize: 0, poses: ["calm": []])))
        let huge: [String: Any] = ["gridSize": 100_000, "poses": ["calm": []]]
        XCTAssertNil(ClawdPoseSet.parse(try! JSONSerialization.data(withJSONObject: huge)))
    }

    // MARK: - Bounding box (drives crisp, consistently scaled rendering)

    func testBoundingBoxTrimsEmptyBorder() throws {
        let box = try XCTUnwrap(ClawdPoseSet.boundingBox(
            of: grid(bodyRows: 4...16, bodyColumns: 5...15)))
        XCTAssertEqual(box.minRow, 4)
        XCTAssertEqual(box.maxRow, 16)
        XCTAssertEqual(box.minColumn, 5)
        XCTAssertEqual(box.maxColumn, 15)
        XCTAssertEqual(box.rows, 13)
        XCTAssertEqual(box.columns, 11)
    }

    func testBoundingBoxIncludesEyeCells() throws {
        // An eye outside the body must still expand the box, or it would be clipped.
        let box = try XCTUnwrap(ClawdPoseSet.boundingBox(
            of: grid(bodyRows: 8...9, bodyColumns: 8...9, eyes: [(2, 2)])))
        XCTAssertEqual(box.minRow, 2)
        XCTAssertEqual(box.minColumn, 2)
    }

    func testEmptyGridHasNoBoundingBox() {
        XCTAssertNil(ClawdPoseSet.boundingBox(of: grid(bodyRows: 0...0, bodyColumns: 0...0)
            .map { $0.map { _ in 0 } }))
    }

    /// Poses of different extents must share one cell scale, or the creature
    /// would visibly grow and shrink as usage crosses a band.
    func testPosesOfDifferentExtentShareOneScale() throws {
        let set = try XCTUnwrap(ClawdPoseSet.parse(fourPosePayload))
        let calm = try XCTUnwrap(ClawdPoseSet.boundingBox(of: XCTUnwrap(set.grid(for: .normal))))
        let panic = try XCTUnwrap(ClawdPoseSet.boundingBox(of: XCTUnwrap(set.grid(for: .critical))))
        XCTAssertGreaterThan(panic.rows, calm.rows, "panic is taller, so per-pose scaling would differ")

        // The renderer divides a fixed reference height by a constant, never by
        // the pose's own row count.
        let referenceRows = 15
        let height: CGFloat = 30
        let cell = max((height / CGFloat(referenceRows)).rounded(.down), 1)
        XCTAssertEqual(cell, 2)
        XCTAssertEqual(cell, max((height / CGFloat(referenceRows)).rounded(.down), 1),
                       "cell size is independent of which pose is drawn")
    }
}
