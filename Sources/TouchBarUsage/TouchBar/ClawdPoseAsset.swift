import AppKit
import TouchBarUsageKit

/// Renders locally generated Clawd pose grids as crisp pixel art.
///
/// Parsing and validation live in `ClawdPoseSet` (in the AppKit-free core, so
/// they are unit tested); this type only locates the generated file and draws it.
///
/// The grids come from `make assets` (see `Scripts/fetch-clawd-assets.sh`) and
/// are written to a **gitignored** directory. Clawd is Anthropic's character and
/// the upstream pose library publishes no licence, so this repository ships none
/// of that artwork — only the code that fetches it onto your own machine. When
/// the file is absent or unreadable, callers fall back to the repository's own
/// placeholder mark. See docs/branding.md.
///
/// Loading happens once, lazily, from disk. **The app never fetches at runtime.**
enum ClawdPoseAsset {

    /// Tallest pose extent across the generated set. Used as a fixed reference so
    /// every pose renders at one scale.
    static let referenceRows = 15

    static let relativePath = "GeneratedAssets/Clawd/clawd-poses.json"
    private static let log = Log(category: "mascot")

    /// Parsed once. A missing or corrupt file yields nil, never a crash.
    static let poseSet: ClawdPoseSet? = load()

    static var isAvailable: Bool { poseSet != nil }

    private static func load() -> ClawdPoseSet? {
        for url in candidateURLs() where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let parsed = ClawdPoseSet.parse(data) {
                log.info("clawd poses loaded", ["count": "\(parsed.poses.count)"])
                return parsed
            }
            log.warning("clawd pose file unusable; using fallback mark")
        }
        return nil
    }

    private static func color(from rgb: ClawdPoseSet.RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// Bundle resources first (a built .app), then the source checkout so
    /// `swift run` picks up freshly generated assets.
    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("clawd-poses.json"))
            urls.append(resources.appendingPathComponent(relativePath))
        }
        let executableDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        urls.append(executableDirectory.appendingPathComponent(relativePath))
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath))
        return urls
    }

    /// Renders the pose for `severity`, preserving aspect ratio.
    ///
    /// Anti-aliasing and interpolation are disabled and each cell is drawn as a
    /// whole-number rectangle, so the pixel art stays sharp rather than being
    /// smoothed by scaling.
    ///
    /// Clawd is drawn in his own colours when the generated file carries them.
    /// Without colours the image becomes a tinted template instead, which still
    /// reads correctly on any bar.
    static func image(for severity: UsageSeverity, height: CGFloat) -> NSImage? {
        guard let set = poseSet,
              let grid = set.grid(for: severity),
              let box = ClawdPoseSet.boundingBox(of: grid)
        else { return nil }

        // Cell size comes from a fixed reference height, not this pose's own row
        // count. Poses differ in extent — `panic` adds shock lines above the body
        // — and sizing per-pose would make the creature grow and shrink as usage
        // crosses a severity band.
        let cellSize = max((height / CGFloat(referenceRows)).rounded(.down), 1)
        let size = NSSize(width: cellSize * CGFloat(box.columns),
                          height: cellSize * CGFloat(box.rows))
        guard size.width > 0, size.height > 0 else { return nil }

        let body = set.bodyColor.map(color(from:))
        let eye = set.eyeColor.map(color(from:))

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return true }
            context.shouldAntialias = false
            context.imageInterpolation = .none

            for rowIndex in box.minRow...box.maxRow {
                let row = grid[rowIndex]
                for columnIndex in box.minColumn...box.maxColumn {
                    let cell = ClawdPoseSet.Cell(rawValue: row[columnIndex])
                    let fill: NSColor?
                    switch cell {
                    case .body:
                        fill = body ?? .black          // black reads as the template mask
                    case .eye:
                        // Without a colour the eye stays transparent, so it still
                        // reads as negative space in template mode.
                        fill = eye
                    default:
                        fill = nil
                    }
                    guard let fill else { continue }
                    fill.setFill()
                    // Grid row 0 is the top; AppKit's origin is bottom-left.
                    let x = CGFloat(columnIndex - box.minColumn) * cellSize
                    let y = CGFloat(box.maxRow - rowIndex) * cellSize
                    NSRect(x: x, y: y, width: cellSize, height: cellSize).fill()
                }
            }
            return true
        }
        // Template rendering discards colour, so it is used only as the fallback
        // when the generated file carried none.
        image.isTemplate = (body == nil)
        return image
    }
}
