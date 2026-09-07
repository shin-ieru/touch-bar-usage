import AppKit
import TouchBarUsageKit

/// Supplies the small character mark shown beside Claude usage.
///
/// This repository ships only an original, generated fallback mark. Anthropic's
/// artwork is **not** bundled: we have not verified redistribution terms, and a
/// public open-source repo is the wrong place to guess. A developer may drop
/// their own image at `LocalAssets/claude-mascot.png` (gitignored) and it is
/// preferred automatically. See docs/branding.md.
enum MascotProvider {

    /// Path checked for a developer-supplied asset, relative to the app bundle
    /// and to the source checkout during `make run`.
    static let localAssetRelativePath = "LocalAssets/claude-mascot.png"

    /// Which source actually supplied the current mascot, for Diagnostics.
    static var activeSource: String {
        if loadLocalAsset() != nil { return "local override" }
        if ClawdPoseAsset.isAvailable { return "Clawd (generated locally)" }
        return "built-in fallback mark"
    }

    /// `severity` selects a Clawd pose when generated assets are present; the
    /// local override and the fallback mark are severity-independent.
    static func mascot(height: CGFloat = 18, severity: UsageSeverity = .normal) -> NSImage {
        if let local = loadLocalAsset() {
            return resized(local, height: height)
        }
        if let clawd = ClawdPoseAsset.image(for: severity, height: height) {
            return clawd
        }
        return fallbackMark(height: height)
    }

    /// Looks for a local override next to the executable, inside the bundle's
    /// Resources, and in the working directory (which covers `swift run`).
    private static func loadLocalAsset() -> NSImage? {
        var candidates: [URL] = []
        let bundle = Bundle.main

        if let resource = bundle.resourceURL {
            candidates.append(resource.appendingPathComponent("claude-mascot.png"))
            candidates.append(resource.appendingPathComponent(localAssetRelativePath))
        }
        // .app/Contents/MacOS/exe → repo root when running from a dev build.
        let executableDirectory = bundle.bundleURL.deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent(localAssetRelativePath))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(localAssetRelativePath))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    private static func resized(_ image: NSImage, height: CGFloat) -> NSImage {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let target = NSSize(width: (height * ratio).rounded(), height: height)
        let output = NSImage(size: target)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .sourceOver, fraction: 1)
        output.unlockFocus()
        return output
    }

    /// Original placeholder: a rounded square with a simple two-dot face and a
    /// mouth. Deliberately generic so it cannot be mistaken for, or impersonate,
    /// any trademarked character.
    ///
    /// Drawn with `NSImage(size:flipped:drawingHandler:)` and an even-odd fill
    /// rather than `lockFocus` plus `.clear` compositing: the latter produced an
    /// image that rendered correctly off-device but did not display as a template
    /// image on the physical Touch Bar.
    private static func fallbackMark(height: CGFloat) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let inset = height * 0.06
            let body = NSRect(x: inset, y: inset,
                              width: height - inset * 2, height: height - inset * 2)

            let path = NSBezierPath(roundedRect: body,
                                    xRadius: height * 0.3, yRadius: height * 0.3)

            // Face features are subpaths; even-odd winding punches them out of
            // the body in a single fill, which keeps the alpha mask clean.
            let eyeSize = height * 0.17
            let eyeY = body.midY + height * 0.05
            for x in [body.midX - height * 0.20, body.midX + height * 0.20 - eyeSize] {
                path.appendOval(in: NSRect(x: x, y: eyeY, width: eyeSize, height: eyeSize))
            }
            path.append(NSBezierPath(
                roundedRect: NSRect(x: body.midX - height * 0.15,
                                    y: body.midY - height * 0.20,
                                    width: height * 0.30, height: height * 0.08),
                xRadius: height * 0.04, yRadius: height * 0.04))

            path.windingRule = .evenOdd
            NSColor.black.setFill()   // colour is ignored once isTemplate is set
            path.fill()
            return true
        }
        image.isTemplate = true   // tints to match the bar it is drawn on
        return image
    }
}
