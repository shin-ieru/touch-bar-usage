import AppKit
import TouchBarUsageKit

/// The **only** file in this project that knows about private Touch Bar APIs.
///
/// ## Why this exists
///
/// A public `NSTouchBar` belongs to the front-most application. This utility must
/// stay reachable while you work in Terminal, VS Code or Xcode, so the public API
/// cannot express it. macOS implements Control Strip items and system-modal bars
/// through private selectors on `NSTouchBar` / `NSTouchBarItem` and through
/// `DFRFoundation`; those are what we use.
///
/// ## Consequences
///
/// Private API means **this app is not appropriate for the Mac App Store** and
/// may break on any macOS update. Everything here resolves dynamically and
/// degrades to an unsupported state rather than crashing. No other file performs
/// `performSelector`, Objective-C runtime lookups, or private framework calls.
///
/// ## The two concepts
///
/// The bridge deliberately exposes exactly two things, matching the product's
/// two states:
///
/// - **Usage tray item** — a small, persistent Control Strip entry point. While
///   only this is installed, macOS keeps its normal Touch Bar behaviour.
/// - **Usage bar** — the expanded system-modal dashboard, presented on demand and
///   dismissed again, restoring the native bar.
///
/// Nothing else in the project passes raw placements or selectors.
///
/// ## Hard-won details
///
/// Two mistakes each produce the same symptom — an item that registers without
/// error and is never drawn:
///
/// 1. **A non-nil `systemTrayItemIdentifier` when presenting a modal bar.** It
///    binds the bar to a tray item; pass nil for a free-standing presentation.
/// 2. **An item view with no concrete frame.** An Auto Layout-only view collapses
///    to zero width. Every view handed to this bridge must carry a real frame.
final class SystemModalTouchBarBridge {

    /// Where a system-modal bar sits relative to Apple's Control Strip.
    ///
    /// Measured on macOS 26.6.2: a system-modal bar is inherently a full-width
    /// presentation, and `placement` only affects whether it is drawn at all in a
    /// given Touch Bar mode. Since the expanded dashboard is intentionally
    /// temporary, covering the strip while open is the accepted behaviour.
    enum Placement: Int {
        case alongsideControlStrip = 0
        case coversControlStrip = 1
    }

    /// Placement for the expanded usage bar. Overridable for re-measuring on a
    /// future macOS release.
    static var usageBarPlacement: Placement {
        if let raw = ProcessInfo.processInfo.environment["TBU_TOUCHBAR_PLACEMENT"],
           let value = Int(raw), let placement = Placement(rawValue: value) {
            return placement
        }
        return .coversControlStrip
    }

    private let trayIdentifier: NSTouchBarItem.Identifier
    private let log = Log(category: "touchbar-bridge")

    private var trayItem: NSCustomTouchBarItem?
    private var usageBar: NSTouchBar?
    private var usageProvider: BarContentProvider?
    private(set) var isPresentingUsageBar = false

    private var usageItemIdentifier: NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(trayIdentifier.rawValue + ".usage")
    }

    // MARK: - Dynamically resolved private API

    private typealias SetControlStripPresence = @convention(c) (NSString, Bool) -> Void
    private typealias SetShowsCloseBox = @convention(c) (Bool) -> Void
    /// The identifier parameter is **optional**; nil gives a free-standing bar.
    private typealias PresentSystemModal =
        @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
    private typealias BarOnlyCall = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

    private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private static func dfrSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dfrHandle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Looks up a *class* method by name and returns a callable typed pointer.
    /// `perform(_:with:)` cannot express the `NSInteger` placement argument.
    private static func classMethod<T>(_ cls: AnyClass, _ name: String, as type: T.Type) -> (fn: T, sel: Selector)? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        return (unsafeBitCast(method_getImplementation(method), to: type), selector)
    }

    private static let setControlStripPresence =
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetControlStripPresence.self)
    private static let setShowsCloseBox =
        dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: SetShowsCloseBox.self)

    private static let presentSystemModal =
        classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                    as: PresentSystemModal.self)
    private static let dismissSystemModal =
        classMethod(NSTouchBar.self, "dismissSystemModalTouchBar:", as: BarOnlyCall.self)
    private static let minimizeSystemModal =
        classMethod(NSTouchBar.self, "minimizeSystemModalTouchBar:", as: BarOnlyCall.self)

    private static let addTrayItemSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTrayItemSelector = NSSelectorFromString("removeSystemTrayItem:")

    private static func respondsToTrayItemSelectors() -> Bool {
        guard let meta = object_getClass(NSTouchBarItem.self) else { return false }
        return meta.instancesRespond(to: addTrayItemSelector)
            && meta.instancesRespond(to: removeTrayItemSelector)
    }

    // MARK: - Availability

    /// Whether the expanded usage bar can be presented at all. When false the app
    /// runs menu-bar-only and says so in Diagnostics.
    static let isUsageBarSupported: Bool = {
        presentSystemModal != nil && dismissSystemModal != nil
    }()

    /// Whether the Control Strip entry point can be registered. Registration
    /// succeeding is *not* proof that macOS draws it — see docs/touchbar-research.md.
    static let isTrayItemSupported: Bool = {
        respondsToTrayItemSelectors() && setControlStripPresence != nil
    }()

    var isUsageBarSupported: Bool { Self.isUsageBarSupported }
    var isTrayItemSupported: Bool { Self.isTrayItemSupported }
    private(set) var isTrayItemInstalled = false

    /// The user's `Touch Bar shows:` setting, for Diagnostics only.
    static var presentationMode: String {
        (CFPreferencesCopyAppValue("PresentationModeGlobal" as CFString,
                                   "com.apple.touchbar.agent" as CFString) as? String)
            ?? "default"
    }

    static var availabilityReport: [DiagnosticEntry] {
        [
            .init(label: "DFRFoundation", value: dfrHandle != nil ? "loaded" : "unavailable"),
            .init(label: "Tray item API", value: isTrayItemSupported ? "available" : "unavailable"),
            .init(label: "Usage bar API", value: isUsageBarSupported ? "supported" : "unsupported"),
            .init(label: "Touch Bar shows", value: presentationMode),
            .init(label: "Usage bar placement", value: "\(usageBarPlacement)"),
        ]
    }

    init(identifier: String) {
        self.trayIdentifier = NSTouchBarItem.Identifier(identifier)
    }

    // MARK: - Usage tray item (normal mode)

    /// Registers the small persistent Control Strip entry point.
    ///
    /// The view must be **small** and carry a concrete frame: the Control Strip
    /// slot is narrow and fixed, and an oversized or unframed view is silently
    /// not drawn. Idempotent.
    @discardableResult
    func installUsageTrayItem(view: NSView) -> Bool {
        guard Self.isTrayItemSupported else {
            log.warning("control strip tray item unsupported on this system")
            return false
        }
        if let existing = trayItem {
            existing.view = view
            return true
        }

        let item = NSCustomTouchBarItem(identifier: trayIdentifier)
        item.view = view
        trayItem = item

        // `addSystemTrayItem:` takes one object argument, so `perform` is exact.
        _ = (NSTouchBarItem.self as AnyObject).perform(Self.addTrayItemSelector, with: item)
        Self.setControlStripPresence?(trayIdentifier.rawValue as NSString, true)
        isTrayItemInstalled = true

        log.info("usage tray item installed", [
            "presentationMode": Self.presentationMode,
            "width": "\(Int(view.frame.width))",
        ])
        return true
    }

    /// Swaps the tray item's view without re-registering it.
    func updateUsageTrayItem(view: NSView) {
        trayItem?.view = view
    }

    func removeUsageTrayItem() {
        guard isTrayItemInstalled else { return }
        Self.setControlStripPresence?(trayIdentifier.rawValue as NSString, false)
        if let item = trayItem, Self.respondsToTrayItemSelectors() {
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.removeTrayItemSelector, with: item)
        }
        trayItem = nil
        isTrayItemInstalled = false
        log.info("usage tray item removed")
    }

    // MARK: - Expanded usage bar (usage mode)

    /// Presents the expanded dashboard. Intentionally temporary: it covers the
    /// strip while open, and `dismissUsageBar()` gives macOS its bar back.
    @discardableResult
    func presentUsageBar(view: NSView) -> Bool {
        guard Self.isUsageBarSupported else {
            log.warning("usage bar unsupported on this system")
            return false
        }

        let provider = BarContentProvider(identifier: usageItemIdentifier, view: view)
        let bar = NSTouchBar()
        bar.delegate = provider
        bar.defaultItemIdentifiers = [usageItemIdentifier]
        usageProvider = provider
        usageBar = bar

        // A close box would duplicate the dashboard's own Close control and eat
        // width; the dashboard owns dismissal.
        Self.setShowsCloseBox?(false)
        present(bar, placement: Self.usageBarPlacement)
        isPresentingUsageBar = true

        log.info("usage bar presented", ["placement": "\(Self.usageBarPlacement)"])
        return true
    }

    /// Swaps the dashboard's content in place (for example switching to a
    /// provider detail page) without re-presenting the bar.
    func updateUsageBar(view: NSView) {
        usageProvider?.view = view
    }

    /// Dismisses the dashboard and returns the Touch Bar to macOS. The tray item
    /// is deliberately left installed.
    func dismissUsageBar() {
        guard isPresentingUsageBar else { return }
        if let bar = usageBar { dismiss(bar) }
        usageBar = nil
        usageProvider = nil
        isPresentingUsageBar = false
        log.info("usage bar dismissed")
    }

    /// Collapses the dashboard without tearing it down.
    func minimizeUsageBar() {
        guard isPresentingUsageBar, let bar = usageBar,
              let (fn, sel) = Self.minimizeSystemModal else { return }
        fn(NSTouchBar.self, sel, bar)
        isPresentingUsageBar = false
        log.info("usage bar minimized")
    }

    // MARK: - Teardown

    /// Removes everything this bridge added. Must run before termination so the
    /// Touch Bar returns to normal and a relaunch leaves no ghost item.
    /// Idempotent — overlapping termination paths must be harmless.
    func teardown() {
        dismissUsageBar()
        removeUsageTrayItem()
        log.info("touch bar presentation torn down")
    }

    // MARK: - Private API calls

    /// The single place the private present selector is invoked.
    /// `systemTrayItemIdentifier` is nil: supplying one binds the bar to a tray
    /// item rather than presenting it free-standing.
    private func present(_ bar: NSTouchBar, placement: Placement) {
        guard let (fn, sel) = Self.presentSystemModal else { return }
        fn(NSTouchBar.self, sel, bar, placement.rawValue, nil)
    }

    private func dismiss(_ bar: NSTouchBar) {
        guard let (fn, sel) = Self.dismissSystemModal else { return }
        fn(NSTouchBar.self, sel, bar)
    }
}

/// Vends one view as the sole item of a touch bar. A separate object because
/// `NSTouchBar.delegate` is weak and the bridge is not an `NSObject`.
private final class BarContentProvider: NSObject, NSTouchBarDelegate {
    private let identifier: NSTouchBarItem.Identifier
    var view: NSView { didSet { item?.view = view } }
    private weak var item: NSCustomTouchBarItem?

    init(identifier: NSTouchBarItem.Identifier, view: NSView) {
        self.identifier = identifier
        self.view = view
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == self.identifier else { return nil }
        let created = NSCustomTouchBarItem(identifier: identifier)
        created.view = view
        item = created
        return created
    }
}
