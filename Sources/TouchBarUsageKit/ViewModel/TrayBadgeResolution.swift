import Foundation

/// Which tier supplied the compact tray badge.
///
/// The policy lives here, free of AppKit, so the fallback order is unit tested
/// rather than asserted in a comment. The drawing itself is in the app target.
public enum TrayBadgeSource: String, Equatable, Sendable, CaseIterable {
    /// A developer's own composed badge from gitignored `LocalAssets/`.
    case localOverride
    /// Clawd's face beside the Codex blossom, both resolved from software
    /// already installed on this machine.
    case composed
    /// The repository's own original badge, drawn in code. What a clean checkout
    /// ships, and what makes the graphic path always available.
    case fallbackGraphic
    /// Text only. A genuine last resort — reached only if even the drawn
    /// fallback cannot be produced.
    case text

    /// True for every tier that puts a real graphic on the bar.
    public var isGraphic: Bool { self != .text }

    public var diagnosticDescription: String {
        switch self {
        case .localOverride:   return "local override"
        case .composed:        return "composed (Clawd + Codex, resolved locally)"
        case .fallbackGraphic: return "built-in fallback badge"
        case .text:            return "text only"
        }
    }
}

public enum TrayBadgeResolution {

    /// Picks the badge tier.
    ///
    /// `canDrawFallback` is effectively always true — the fallback is drawn in
    /// code and has nothing to fail on — which is what guarantees the tray item
    /// never has to fall back to plain text in practice. It is a parameter only
    /// so the degenerate case stays covered.
    public static func source(hasLocalOverride: Bool,
                              canCompose: Bool,
                              canDrawFallback: Bool = true) -> TrayBadgeSource {
        if hasLocalOverride { return .localOverride }
        if canCompose { return .composed }
        if canDrawFallback { return .fallbackGraphic }
        return .text
    }
}
