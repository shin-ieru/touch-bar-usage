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

    static func mascot(height: CGFloat = 18) -> NSImage {
        if let local = loadLocalAsset() {
            return resized(local, height: height)
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

    /// Original placeholder: a rounded square with a simple two-dot face. It is
    /// deliberately generic so it cannot be mistaken for, or impersonate, any
    /// trademarked character.
    private static func fallbackMark(height: CGFloat) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset = height * 0.08
        let body = NSRect(x: inset, y: inset, width: height - inset * 2, height: height - inset * 2)
        let path = NSBezierPath(roundedRect: body, xRadius: height * 0.3, yRadius: height * 0.3)
        NSColor.labelColor.setFill()
        path.fill()

        // Eyes punched out, so the mark reads on both light and dark bars.
        let eyeSize = height * 0.16
        let eyeY = body.midY + height * 0.06
        NSColor.clear.set()
        NSGraphicsContext.current?.compositingOperation = .clear
        for x in [body.midX - height * 0.17, body.midX + height * 0.17 - eyeSize] {
            NSBezierPath(ovalIn: NSRect(x: x, y: eyeY, width: eyeSize, height: eyeSize)).fill()
        }
        // A small mouth line.
        let mouth = NSRect(x: body.midX - height * 0.14, y: body.midY - height * 0.19,
                           width: height * 0.28, height: height * 0.07)
        NSBezierPath(roundedRect: mouth, xRadius: height * 0.035, yRadius: height * 0.035).fill()

        image.unlockFocus()
        image.isTemplate = true   // tints correctly against the Touch Bar
        return image
    }
}
