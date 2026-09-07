import AppKit
import TouchBarUsageKit

/// Builds the compact Claude + Codex mark for the Touch Bar tray slot.
///
/// The tray item is an entry point, not a dashboard: it has to read as
/// "Claude + Codex" in a slot roughly 64 pt wide, on an OLED-black bar, at a
/// glance. So this is its own pipeline rather than a shrunk-down reuse of the
/// dashboard artwork — the full Clawd sprite collapses into a smudge at this
/// size, and the Codex tile is the wrong shape entirely.
///
/// ## Resolution order
///
/// 1. `LocalAssets/combined-tray-badge.png` — a developer's own composed badge;
/// 2. a **composed** badge: Clawd's face beside the Codex blossom, both resolved
///    from software already on this machine;
/// 3. the repository-safe fallback badge, drawn in code (original artwork);
/// 4. text, handled by `UsageTrayView`, only if even that fails.
///
/// Tiers 1 and 2 use artwork this repository does not redistribute; tier 3 is
/// original and is what a clean checkout ships. See docs/branding.md.
enum CombinedTrayBadgeResolver {

    /// Design metrics for the tray slot. Deliberately small and fixed.
    ///
    /// The Control Strip slot has a fixed width that does not grow to fit: an
    /// earlier revision sized Clawd's face generously and pushed the blossom off
    /// the right edge on hardware. Clawd's face is inherently wide (roughly 11×5
    /// grid cells), so it is the constraint, and `maximumContentWidth` is a hard
    /// cap enforced after composition.
    enum Metrics {
        static let height: CGFloat = 22
        /// Gap between the two marks. Enough to read as two things, not so much
        /// that they stop reading as one badge.
        static let gap: CGFloat = 3
        /// The blossom is squarer than Clawd's face, so a little more height
        /// makes them look optically equal.
        static let blossomHeight: CGFloat = 14
        /// Snaps down to whole grid cells, so this yields a 2 pt cell.
        static let clawdHeight: CGFloat = 12
        /// Artwork must never exceed this; the composite is scaled down if it
        /// somehow does.
        static let maximumContentWidth: CGFloat = 44
    }

    static let localAssetRelativePath = "LocalAssets/combined-tray-badge.png"

    private static let log = Log(category: "tray-badge")

    /// Which tier supplied the badge, for Diagnostics. The ordering policy lives
    /// in `TrayBadgeResolution` so it can be unit tested without AppKit.
    static var activeSource: TrayBadgeSource {
        TrayBadgeResolution.source(
            hasLocalOverride: loadLocalOverride() != nil,
            canCompose: composedBadge(height: Metrics.height) != nil)
    }

    /// Always returns an image: the fallback is drawn in code and cannot fail, so
    /// the tray item never has to install without a graphic.
    static func badge(height: CGFloat = Metrics.height) -> NSImage {
        switch activeSource {
        case .localOverride:
            if let local = loadLocalOverride() { return resized(local, height: height) }
        case .composed:
            if let composed = composedBadge(height: height) { return composed }
        case .fallbackGraphic, .text:
            break
        }
        return fallbackBadge(height: height)
    }

    // MARK: - Tier 1: local override

    private static func loadLocalOverride() -> NSImage? {
        var candidates: [URL] = []
        let bundle = Bundle.main
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("combined-tray-badge.png"))
            candidates.append(resources.appendingPathComponent(localAssetRelativePath))
        }
        candidates.append(bundle.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(localAssetRelativePath))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(localAssetRelativePath))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url), image.size.height > 0 { return image }
        }
        return nil
    }

    // MARK: - Tier 2: composed from locally resolved marks

    /// Clawd's face and the Codex blossom, side by side in one image.
    ///
    /// Both source marks are template images (alpha silhouettes), so the result
    /// is templated too and tints to whatever the bar is doing. That is also what
    /// keeps this safe from the opaque-tile problem that once made the Codex mark
    /// render as a solid black square: only vector/alpha sources reach here.
    static func composedBadge(height: CGFloat) -> NSImage? {
        let clawdHeight = (height * Metrics.clawdHeight / Metrics.height).rounded()
        let blossomHeight = (height * Metrics.blossomHeight / Metrics.height).rounded()

        guard let clawd = ClawdPoseAsset.headImage(height: clawdHeight),
              let codex = CodexIconAsset.image(height: blossomHeight),
              clawd.size.width > 0, codex.size.width > 0
        else { return nil }

        var width = clawd.size.width + Metrics.gap + codex.size.width
        var height = height
        // Hard cap: uniformly scale the whole badge rather than let either mark
        // run off the edge of the slot.
        if width > Metrics.maximumContentWidth {
            let scale = Metrics.maximumContentWidth / width
            width = Metrics.maximumContentWidth
            height = (height * scale).rounded()
        }
        let size = NSSize(width: width.rounded(), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return true }
            context.imageInterpolation = .none

            // Vertically centred independently, so the two marks look aligned
            // even though their natural heights differ.
            clawd.draw(in: NSRect(x: 0,
                                  y: ((size.height - clawd.size.height) / 2).rounded(),
                                  width: clawd.size.width, height: clawd.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            codex.draw(in: NSRect(x: (clawd.size.width + Metrics.gap).rounded(),
                                  y: ((size.height - codex.size.height) / 2).rounded(),
                                  width: codex.size.width, height: codex.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Tier 3: repository-safe fallback

    /// Original artwork: a simple two-eyed face beside a six-petal rosette.
    ///
    /// Deliberately generic. It gestures at "a character and a flower" — enough
    /// to read as two providers — without imitating either company's mark, so it
    /// is safe to ship in a public repository. A clean checkout with no local or
    /// generated assets gets this.
    ///
    /// Drawn with `NSImage(size:flipped:drawingHandler:)` and even-odd fills,
    /// because `lockFocus` plus `.clear` compositing produced images that
    /// previewed correctly and did not display as templates on the physical bar.
    static func fallbackBadge(height: CGFloat) -> NSImage {
        let faceWidth = (height * 1.15).rounded()
        let rosetteWidth = height.rounded()
        let size = NSSize(width: faceWidth + Metrics.gap + rosetteWidth, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()   // colour is ignored once isTemplate is set

            // Left: a rounded face with two punched-out eyes.
            let faceInset = height * 0.12
            let face = NSRect(x: 0, y: faceInset,
                              width: faceWidth, height: height - faceInset * 2)
            let facePath = NSBezierPath(roundedRect: face,
                                        xRadius: height * 0.28, yRadius: height * 0.28)
            let eye = height * 0.17
            let eyeY = face.midY - eye / 2 + height * 0.04
            for x in [face.midX - height * 0.26, face.midX + height * 0.26 - eye] {
                facePath.appendOval(in: NSRect(x: x, y: eyeY, width: eye, height: eye))
            }
            facePath.windingRule = .evenOdd
            facePath.fill()

            // Right: a six-petal rosette with an open centre.
            let centre = NSPoint(x: faceWidth + Metrics.gap + rosetteWidth / 2, y: height / 2)
            let petalLength = height * 0.42
            let petalWidth = height * 0.20
            let rosette = NSBezierPath()
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3
                let petal = NSBezierPath(ovalIn: NSRect(
                    x: -petalWidth / 2, y: petalLength * 0.18,
                    width: petalWidth, height: petalLength))
                let transform = AffineTransform(translationByX: centre.x, byY: centre.y)
                var rotation = AffineTransform(rotationByRadians: CGFloat(angle))
                rotation.append(transform)
                petal.transform(using: rotation)
                rosette.append(petal)
            }
            rosette.appendOval(in: NSRect(x: centre.x - height * 0.09,
                                          y: centre.y - height * 0.09,
                                          width: height * 0.18, height: height * 0.18))
            rosette.windingRule = .evenOdd
            rosette.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Helpers

    private static func resized(_ image: NSImage, height: CGFloat) -> NSImage {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let target = NSSize(width: (height * ratio).rounded(), height: height)
        let output = NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // A user-supplied badge may be full colour; templating it would flatten
        // that to a silhouette, so it is left as authored.
        output.isTemplate = false
        return output
    }
}
