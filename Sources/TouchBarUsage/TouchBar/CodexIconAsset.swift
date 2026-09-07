import AppKit
import TouchBarUsageKit

/// Resolves a Codex mark from software already installed on this machine.
///
/// **Nothing is downloaded and nothing is committed.** The Codex mark is
/// OpenAI's; this repository redistributes none of it. The icon is read at
/// runtime from an OpenAI application the user already has, exactly as the Clawd
/// poses are generated locally rather than vendored. If no such installation is
/// found, callers fall back to the repository's own placeholder mark.
///
/// See docs/branding.md.
enum CodexIconAsset {

    private static let log = Log(category: "codex-icon")

    /// A candidate asset plus how it should be drawn.
    ///
    /// The distinction matters: the vector glyphs are transparent artwork whose
    /// alpha makes a clean template mask, while the bundled PNG is an **opaque
    /// square tile**. Templating that tile paints a solid black square, which is
    /// exactly what happened before this was split apart.
    private struct Candidate {
        let url: URL
        let isTemplateSafe: Bool
    }

    /// Candidate locations, in preference order. Deliberately several — the
    /// point is not to assume one fixed path, and any of them may be absent.
    private static func candidateURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []

        // A developer override lives in gitignored LocalAssets and is handled by
        // MascotProvider before this type is consulted.

        // VS Code / Cursor / VSCodium extension installs, newest version last so
        // the sort below prefers the most recent.
        let extensionRoots = [
            home.appendingPathComponent(".vscode/extensions"),
            home.appendingPathComponent(".vscode-insiders/extensions"),
            home.appendingPathComponent(".cursor/extensions"),
            home.appendingPathComponent(".vscode-oss/extensions"),
        ]
        for root in extensionRoots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            let matches = contents
                .filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .reversed()
            for match in matches {
                // Vector glyphs first: transparent artwork that tints cleanly.
                urls.append(match.appendingPathComponent("resources/blossom-black.svg"))
                urls.append(match.appendingPathComponent("resources/blossom-white.svg"))
                // The PNG is an opaque tile; usable, but drawn in its own colours.
                urls.append(match.appendingPathComponent("resources/blossom.dark.png"))
            }
        }

        // A standalone desktop app, if one is installed.
        for app in ["/Applications/ChatGPT.app", "/Applications/Codex.app"] {
            urls.append(URL(fileURLWithPath: app)
                .appendingPathComponent("Contents/Resources/AppIcon.icns"))
        }

        return urls
    }

    /// Resolved once. A missing installation yields nil, never a crash.
    private static let resolved: (image: NSImage, isTemplateSafe: Bool)? = {
        for url in candidateURLs() where FileManager.default.fileExists(atPath: url.path) {
            guard let image = NSImage(contentsOf: url), image.size.height > 0 else { continue }
            // Only vector glyphs are safe to tint; a raster tile is not.
            let templateSafe = url.pathExtension.lowercased() == "svg"
            log.info("codex icon resolved", [
                "source": url.pathExtension,
                "template": "\(templateSafe)",
            ])
            return (image, templateSafe)
        }
        log.info("codex icon not found; using fallback mark")
        return nil
    }()

    static var isAvailable: Bool { resolved != nil }

    /// Renders the mark at the requested height, preserving aspect ratio.
    ///
    /// Drawn as a template image so it tints to the bar rather than depending on
    /// whether the source asset happened to be the light or dark variant.
    static func image(height: CGFloat) -> NSImage? {
        guard let resolved else { return nil }
        let source = resolved.image

        // Leave a little breathing room so the glyph does not touch the chip edge.
        let drawHeight = (height * 0.72).rounded()
        let ratio = source.size.width / source.size.height
        let target = NSSize(width: (drawHeight * ratio).rounded(), height: drawHeight)

        let output = NSImage(size: target, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // Templating an opaque tile would paint a solid rectangle, so only the
        // vector glyphs are tinted; a raster tile keeps its own colours.
        output.isTemplate = resolved.isTemplateSafe
        return output
    }
}
