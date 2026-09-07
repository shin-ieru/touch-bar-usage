import XCTest
@testable import TouchBarUsageKit

/// The face crop that drives the compact tray badge.
///
/// The full creature is unreadable at tray size, so the badge shows only the
/// face. These cover the cropping rules; whether the result *looks* right on an
/// OLED-black bar is a hardware question, recorded in manual-test-results.md.
final class ClawdHeadCropTests: XCTestCase {

    /// A creature shaped like the real Clawd: a head block, an eye row, wider
    /// arms below it, then legs.
    private func creature(size: Int = 20) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: size), count: size)
        func fill(_ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>, _ value: Int = 1) {
            for r in rows { for c in columns { grid[r][c] = value } }
        }
        fill(4...5, 5...15)          // head
        fill(6...7, 5...15)          // eye band
        grid[6][7] = 2; grid[6][13] = 2
        grid[7][7] = 2; grid[7][13] = 2
        fill(8...9, 3...17)          // arms — wider than the head
        fill(10...13, 5...15)        // body
        fill(14...16, 5...6)         // legs
        return grid
    }

    func testHeadCropStopsBelowTheEyes() throws {
        let box = try XCTUnwrap(ClawdPoseSet.headBoundingBox(of: creature()))
        XCTAssertEqual(box.minRow, 4, "starts at the top of the creature")
        XCTAssertEqual(box.maxRow, 8, "last eye row (7) plus one row of padding")
        XCTAssertLessThan(box.rows, 8, "the legs and body are excluded")
    }

    /// The arms are wider than the head. Measuring columns across all cropped
    /// rows produced a stepped anvil silhouette rather than a face, so width
    /// comes from the top row alone.
    func testHeadCropTakesWidthFromTheTopRowNotTheArms() throws {
        let box = try XCTUnwrap(ClawdPoseSet.headBoundingBox(of: creature()))
        XCTAssertEqual(box.minColumn, 5)
        XCTAssertEqual(box.maxColumn, 15)
        XCTAssertEqual(box.columns, 11, "arms at columns 3...17 are cropped away")

        let full = try XCTUnwrap(ClawdPoseSet.boundingBox(of: creature()))
        XCTAssertEqual(full.columns, 15, "the full body really is wider")
        XCTAssertLessThan(box.columns, full.columns)
    }

    func testHeadCropIsSmallerThanTheFullBody() throws {
        let head = try XCTUnwrap(ClawdPoseSet.headBoundingBox(of: creature()))
        let full = try XCTUnwrap(ClawdPoseSet.boundingBox(of: creature()))
        XCTAssertLessThan(head.rows, full.rows)
        XCTAssertLessThan(head.rows * head.columns, full.rows * full.columns)
    }

    /// Without eyes there is nothing to anchor on; callers fall back to the full
    /// bounding box rather than guessing.
    func testGridWithoutEyesHasNoHeadCrop() {
        var grid = creature()
        for row in grid.indices {
            for column in grid[row].indices where grid[row][column] == 2 {
                grid[row][column] = 1
            }
        }
        XCTAssertNil(ClawdPoseSet.headBoundingBox(of: grid))
        XCTAssertNotNil(ClawdPoseSet.boundingBox(of: grid), "full body still resolves")
    }

    func testEmptyGridHasNoHeadCrop() {
        let empty = Array(repeating: Array(repeating: 0, count: 20), count: 20)
        XCTAssertNil(ClawdPoseSet.headBoundingBox(of: empty))
    }

    /// The crop must survive a pose whose body sits higher or lower, since it is
    /// derived from where the eyes actually are.
    func testHeadCropFollowsAShiftedPose() throws {
        var shifted = Array(repeating: Array(repeating: 0, count: 20), count: 20)
        let original = creature()
        for row in 0..<18 { shifted[row + 2] = original[row] }

        let box = try XCTUnwrap(ClawdPoseSet.headBoundingBox(of: shifted))
        XCTAssertEqual(box.minRow, 6, "top of the creature moved down by two")
        XCTAssertEqual(box.maxRow, 10)
        XCTAssertEqual(box.columns, 11, "width is unchanged by the shift")
    }

    func testPaddingIsClampedToTheCreature() throws {
        let box = try XCTUnwrap(ClawdPoseSet.headBoundingBox(of: creature(), padding: 100))
        let full = try XCTUnwrap(ClawdPoseSet.boundingBox(of: creature()))
        XCTAssertEqual(box.maxRow, full.maxRow, "padding cannot run past the creature")
    }
}
