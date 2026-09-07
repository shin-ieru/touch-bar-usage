import AppKit
import TouchBarUsageKit

/// The **only** file in this project that knows about private Touch Bar APIs.
///
/// ## Why this exists
///
/// A public `NSTouchBar` belongs to the front-most application. This app's entire
/// purpose is to stay visible while you work in Terminal, VS Code, Xcode or
/// anything else, so the public API cannot express it. macOS implements
/// system-modal bars through private selectors on `NSTouchBar` and through
/// `DFRFoundation`; those are what we use.
///
/// ## Consequences
///
/// Using private API means **this app is not appropriate for the Mac App Store**
/// and may break on any macOS update. Everything here resolves dynamically and
/// degrades to `isSupported == false` rather than crashing. No other file
/// performs `performSelector`, Objective-C runtime lookups, or private framework
/// calls.
///
/// ## Coexistence with Apple's Control Strip
///
/// The bar is presented *alongside* Apple's native Control Strip, so brightness,
/// volume, mute and media controls keep working. Two things are required for
/// that, and getting either wrong silently costs you the native controls or the
/// widget:
///
/// 1. `placement` must be `.alongsideControlStrip` (`0`), not `.coversControlStrip` (`1`);
/// 2. `systemTrayItemIdentifier` must be **nil**.
///
/// Passing a non-nil tray identifier with placement `0` binds the bar to a
/// Control Strip tray item, and third-party tray items are not rendered on
/// macOS 26 — so the widget vanishes. That combination is what made an earlier
/// revision of this file conclude, wrongly, that coexistence was impossible.
final class SystemModalTouchBarBridge {

    /// Where a system-modal bar sits relative to Apple's Control Strip.
    ///
    /// Verified on macOS 26.6.2 — see docs/touchbar-research.md.
    enum Placement: Int {
        /// Shares the bar: our content on the left, Apple's Control Strip intact
        /// on the right. Requires a nil `systemTrayItemIdentifier`.
        case alongsideControlStrip = 0
        /// Takes the entire strip, hiding the native controls. Used only for the
        /// transient detail view, which needs the full width.
        case coversControlStrip = 1
    }

    /// Placement used for the compact widget.
    ///
    /// Measured on macOS 26.6.2 — neither value achieves coexistence, because a
    /// system-modal bar is inherently a full-width presentation:
    ///
    /// | Touch Bar mode     | placement 0        | placement 1        |
    /// | ------------------ | ------------------ | ------------------ |
    /// | `fullControlStrip` | **not drawn**      | drawn, covers bar  |
    /// | `app`              | drawn, covers bar  | drawn, covers bar  |
    ///
    /// `1` is the default because it is the only value that draws in every mode.
    /// Override with `TBU_TOUCHBAR_PLACEMENT`.
    static var compactPlacement: Placement {
        if let raw = ProcessInfo.processInfo.environment["TBU_TOUCHBAR_PLACEMENT"],
           let value = Int(raw), let placement = Placement(rawValue: value) {
            return placement
        }
        return .coversControlStrip
    }

    private let identifier: NSTouchBarItem.Identifier
    private let log = Log(category: "touchbar-bridge")

    private var trayItem: NSCustomTouchBarItem?
    private var compactBar: NSTouchBar?
    private var compactProvider: BarContentProvider?
    private var detailBar: NSTouchBar?
    private(set) var isPresentingDetail = false

    private var compactItemIdentifier: NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(identifier.rawValue + ".compact")
    }

    // MARK: - Dynamically resolved private API

    private typealias SetShowsCloseBox = @convention(c) (Bool) -> Void
    private typealias SetControlStripPresence = @convention(c) (NSString, Bool) -> Void
    /// The identifier parameter is **optional** — passing nil is what allows the
    /// bar to share the strip rather than bind to a tray item.
    private typealias PresentSystemModal =
        @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString?) -> Void
    private typealias DismissSystemModal = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

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

    private static let setShowsCloseBox =
        dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: SetShowsCloseBox.self)
    private static let setControlStripPresence =
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetControlStripPresence.self)

    private static let addTrayItemSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTrayItemSelector = NSSelectorFromString("removeSystemTrayItem:")

    private static func respondsToTrayItemSelectors() -> Bool {
        guard let meta = object_getClass(NSTouchBarItem.self) else { return false }
        return meta.instancesRespond(to: addTrayItemSelector)
            && meta.instancesRespond(to: removeTrayItemSelector)
    }

    private static let presentSystemModal =
        classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                    as: PresentSystemModal.self)
    private static let dismissSystemModal =
        classMethod(NSTouchBar.self, "dismissSystemModalTouchBar:", as: DismissSystemModal.self)

    // MARK: - Availability

    /// Whether every private entry point we need resolved on this system. When
    /// false, the app runs menu-bar-only and says so in Diagnostics.
    static let isSupported: Bool = {
        presentSystemModal != nil && dismissSystemModal != nil
    }()

    var isSupported: Bool { Self.isSupported }

    /// The user's `Touch Bar shows:` setting, for Diagnostics only. Coexistence
    /// works regardless of this setting.
    static var presentationMode: String {
        (CFPreferencesCopyAppValue("PresentationModeGlobal" as CFString,
                                   "com.apple.touchbar.agent" as CFString) as? String)
            ?? "default"
    }

    /// Human-readable, non-sensitive account of what resolved, for Diagnostics.
    static var availabilityReport: [DiagnosticEntry] {
        [
            .init(label: "DFRFoundation", value: dfrHandle != nil ? "loaded" : "unavailable"),
            .init(label: "Present system modal", value: presentSystemModal != nil ? "available" : "unavailable"),
            .init(label: "Dismiss system modal", value: dismissSystemModal != nil ? "available" : "unavailable"),
            .init(label: "System modal bridge", value: isSupported ? "supported" : "unsupported"),
            .init(label: "Touch Bar shows", value: presentationMode),
            .init(label: "Compact placement", value: "\(compactPlacement)"),
        ]
    }

    init(identifier: String) {
        self.identifier = NSTouchBarItem.Identifier(identifier)
    }

    // MARK: - Presentation

    /// Registers the widget as a Control Strip item, which is Apple's own
    /// mechanism for coexisting with the native controls.
    ///
    /// An earlier revision concluded this "never renders" on macOS 26. That was
    /// wrong: the item view was Auto Layout-only with no concrete frame, so it
    /// collapsed to zero width — the same defect that made `placement: 0`
    /// appear not to work. The view passed here must carry a real frame.
    @discardableResult
    func presentControlStripItem(view: NSView) -> Bool {
        guard Self.isSupported, Self.respondsToTrayItemSelectors(),
              Self.setControlStripPresence != nil else {
            log.warning("control strip item unsupported on this system")
            return false
        }

        if let existing = trayItem {
            existing.view = view
            return true
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        trayItem = item

        // `addSystemTrayItem:` takes a single object argument, so `perform` is
        // exact here; the multi-argument present call uses a typed pointer.
        _ = (NSTouchBarItem.self as AnyObject).perform(Self.addTrayItemSelector, with: item)
        Self.setControlStripPresence?(identifier.rawValue as NSString, true)

        log.info("control strip item registered", ["presentationMode": Self.presentationMode])
        return true
    }

    /// Presents the compact widget beside Apple's Control Strip. Idempotent.
    @discardableResult
    func presentAlongsideControlStrip(view: NSView) -> Bool {
        guard Self.isSupported else {
            log.warning("system modal touch bar unsupported on this system")
            return false
        }

        if let provider = compactProvider {
            provider.view = view
            return true
        }

        let provider = BarContentProvider(identifier: compactItemIdentifier, view: view)
        let bar = NSTouchBar()
        bar.delegate = provider
        bar.defaultItemIdentifiers = [compactItemIdentifier]
        compactProvider = provider
        compactBar = bar

        present(bar, placement: Self.compactPlacement)
        log.info("touch bar widget presented", [
            "placement": "\(Self.compactPlacement)",
            "presentationMode": Self.presentationMode,
        ])
        return true
    }

    /// Swaps the view shown in the compact widget without re-presenting.
    func update(view: NSView) {
        compactProvider?.view = view
    }

    /// Shows the expanded detail bar. It covers the strip because the detail rows
    /// need the full width; "Done" restores the coexisting compact widget.
    func presentDetail(_ bar: NSTouchBar) {
        detailBar = bar
        isPresentingDetail = true
        present(bar, placement: .coversControlStrip)
        log.debug("detail bar presented")
    }

    /// Dismisses the detail bar and restores the compact widget alongside the
    /// Control Strip.
    func dismissDetail() {
        guard isPresentingDetail else { return }
        if let bar = detailBar { dismiss(bar) }
        detailBar = nil
        isPresentingDetail = false

        if let bar = compactBar {
            present(bar, placement: Self.compactPlacement)
        }
        log.debug("detail bar dismissed")
    }

    /// Removes everything this bridge presented. Must run before termination so
    /// the Touch Bar returns to normal and a relaunch leaves no ghost item.
    /// Idempotent — overlapping termination paths must be harmless.
    func dismiss() {
        if let bar = detailBar { dismiss(bar) }
        if let bar = compactBar { dismiss(bar) }
        Self.setControlStripPresence?(identifier.rawValue as NSString, false)
        if let item = trayItem, Self.respondsToTrayItemSelectors() {
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.removeTrayItemSelector, with: item)
        }
        trayItem = nil
        detailBar = nil
        compactBar = nil
        compactProvider = nil
        isPresentingDetail = false
        log.info("touch bar presentation removed")
    }

    // MARK: - Private API calls

    /// The single place the private present selector is invoked.
    ///
    /// `systemTrayItemIdentifier` is deliberately nil: supplying one binds the
    /// bar to a Control Strip tray item, which macOS 26 does not render.
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
