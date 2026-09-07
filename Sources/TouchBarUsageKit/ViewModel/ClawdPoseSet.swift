import Foundation

/// Parsed Clawd pose grids, independent of any drawing framework.
///
/// The grids are produced at build time by `make assets` and written to a
/// **gitignored** directory: Clawd is Anthropic's character and the upstream pose
/// library publishes no licence, so this repository redistributes none of that
/// artwork. See docs/branding.md.
///
/// Parsing lives here, in the AppKit-free core, so the validation rules — which
/// decide whether the app shows Clawd or falls back to its own mark — are unit
/// tested without a Touch Bar, a bundle, or a network.
public struct ClawdPoseSet: Equatable, Sendable {

    /// Grid cell meanings, matching the upstream engine's legend.
    public enum Cell: Int, Sendable {
        case empty = 0
        case body = 1
        case eye = 2
    }

    public let gridSize: Int
    public let poses: [String: [[Int]]]
    /// Colours as generated upstream, `#RRGGBB`. Nil when extraction failed, in
    /// which case the renderer falls back to a tinted template.
    public let bodyColor: RGB?
    public let eyeColor: RGB?

    public init(gridSize: Int, poses: [String: [[Int]]],
                bodyColor: RGB? = nil, eyeColor: RGB? = nil) {
        self.gridSize = gridSize
        self.poses = poses
        self.bodyColor = bodyColor
        self.eyeColor = eyeColor
    }

    /// A colour in 0...1 components, so the core stays free of AppKit.
    public struct RGB: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Parses `#RGB` and `#RRGGBB`. Returns nil for anything else, so a
        /// malformed colour degrades to the template rather than drawing black.
        public init?(hex: String) {
            var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("#") { text.removeFirst() }
            if text.count == 3 {
                text = text.map { "\($0)\($0)" }.joined()
            }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            self.init(red:   Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue:  Double(value & 0xFF) / 255)
        }
    }

    /// Pose shown for each severity band. Falls back to `calm` when a pose is
    /// missing, so a partially generated set still renders something sensible.
    public static func poseName(for severity: UsageSeverity) -> String {
        switch severity {
        case .normal:   return "calm"
        case .elevated: return "alert"
        case .warning:  return "worried"
        case .critical: return "panic"
        }
    }

    public func grid(for severity: UsageSeverity) -> [[Int]]? {
        poses[Self.poseName(for: severity)] ?? poses["calm"] ?? poses.values.first
    }

    /// Strict parsing: a truncated, wrong-shaped, or out-of-range file is
    /// rejected outright rather than drawn as garbage.
    public static func parse(_ data: Data) -> ClawdPoseSet? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let gridSize = root["gridSize"] as? Int, gridSize > 0, gridSize <= 128,
            let rawPoses = root["poses"] as? [String: Any]
        else { return nil }

        var poses: [String: [[Int]]] = [:]
        for (name, value) in rawPoses {
            guard let rows = value as? [[Int]],
                  rows.count == gridSize,
                  rows.allSatisfy({ row in
                      row.count == gridSize && row.allSatisfy { Cell(rawValue: $0) != nil }
                  })
            else { continue }   // drop the bad pose, keep the good ones
            poses[name] = rows
        }
        guard !poses.isEmpty else { return nil }
        return ClawdPoseSet(
            gridSize: gridSize,
            poses: poses,
            bodyColor: (root["bodyColor"] as? String).flatMap(RGB.init(hex:)),
            eyeColor: (root["eyeColor"] as? String).flatMap(RGB.init(hex:))
        )
    }

    public struct BoundingBox: Equatable, Sendable {
        public let minRow: Int, maxRow: Int, minColumn: Int, maxColumn: Int
        public var rows: Int { maxRow - minRow + 1 }
        public var columns: Int { maxColumn - minColumn + 1 }
    }

    /// Trims the empty border so the creature fills the space it is given.
    /// Returns nil for a wholly empty grid.
    public static func boundingBox(of grid: [[Int]]) -> BoundingBox? {
        var minRow = Int.max, maxRow = Int.min
        var minColumn = Int.max, maxColumn = Int.min

        for (rowIndex, row) in grid.enumerated() {
            for (columnIndex, value) in row.enumerated() where value != Cell.empty.rawValue {
                minRow = min(minRow, rowIndex)
                maxRow = max(maxRow, rowIndex)
                minColumn = min(minColumn, columnIndex)
                maxColumn = max(maxColumn, columnIndex)
            }
        }
        guard minRow <= maxRow, minColumn <= maxColumn else { return nil }
        return BoundingBox(minRow: minRow, maxRow: maxRow,
                           minColumn: minColumn, maxColumn: maxColumn)
    }
}
