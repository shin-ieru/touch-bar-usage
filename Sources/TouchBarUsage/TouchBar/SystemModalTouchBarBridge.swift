import AppKit
import TouchBarUsageKit

/// The **only** file in this project that knows about private Touch Bar APIs.
///
/// ## Why this exists
///
/// A public `NSTouchBar` belongs to the front-most application. This app's entire
/// purpose is to stay visible while you work in Terminal, VS Code, Xcode or
/// anything else, so the public API cannot express it. macOS implements the
/// Control Strip and system-modal bars through private selectors on `NSTouchBar`
/// / `NSTouchBarItem` and through `DFRFoundation`; those are what we use.
///
/// ## Consequences
///
/// Using private API means **this app is not appropriate for the Mac App Store**
/// and may break on any macOS update. Everything here therefore resolves
/// dynamically and degrades to `isSupported == false` rather than crashing. No
/// other file performs `performSelector`, Objective-C runtime lookups, or
/// private framework calls.
///
/// ## Approach
///
/// We register a *Control Strip item* rather than taking over the whole bar, so
/// volume, brightness and media controls keep working alongside us (see
/// docs/touchbar-research.md).
final class SystemModalTouchBarBridge {

    /// Where a system-modal bar sits relative to the Control Strip. `1` places it
    /// alongside the strip rather than replacing the whole bar.
    private enum Placement {
        static let besideControlStrip = 1
    }

    private let identifier: NSTouchBarItem.Identifier
    private let log = Log(category: "touchbar-bridge")

    private var trayItem: NSCustomTouchBarItem?
    private var presentedBar: NSTouchBar?
    private(set) var isPresentingModal = false

    // MARK: - Dynamically resolved private API

    private typealias SetControlStripPresence = @convention(c) (NSString, Bool) -> Void
    private typealias SetShowsCloseBox = @convention(c) (Bool) -> Void
    private typealias PresentSystemModal = @convention(c) (AnyObject, Selector, NSTouchBar, Int, NSString) -> Void
    private typealias DismissSystemModal = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
    private typealias MinimizeSystemModal = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

    private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private static func dfrSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dfrHandle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Looks up a *class* method by name and returns a callable typed pointer.
    private static func classMethod<T>(_ cls: AnyClass, _ name: String, as type: T.Type) -> (fn: T, sel: Selector)? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        return (unsafeBitCast(method_getImplementation(method), to: type), selector)
    }

    private static let setControlStripPresence =
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetControlStripPresence.self)
    private static let setShowsCloseBox =
        dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: SetShowsCloseBox.self)

    private static let presentModal =
        classMethod(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                    as: PresentSystemModal.self)
    private static let dismissModal =
        classMethod(NSTouchBar.self, "dismissSystemModalTouchBar:", as: DismissSystemModal.self)
    private static let minimizeModal =
        classMethod(NSTouchBar.self, "minimizeSystemModalTouchBar:", as: MinimizeSystemModal.self)

    private static let addTrayItemSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTrayItemSelector = NSSelectorFromString("removeSystemTrayItem:")

    private static func respondsToTrayItemSelectors() -> Bool {
        guard let meta = object_getClass(NSTouchBarItem.self) else { return false }
        return meta.instancesRespond(to: addTrayItemSelector)
            && meta.instancesRespond(to: removeTrayItemSelector)
    }

    // MARK: - Public surface

    /// Whether every private entry point we need resolved on this system. When
    /// false, the app runs menu-bar-only and says so in Diagnostics.
    static let isSupported: Bool = {
        setControlStripPresence != nil
            && presentModal != nil
            && dismissModal != nil
            && respondsToTrayItemSelectors()
    }()

    var isSupported: Bool { Self.isSupported }

    /// A human-readable, non-sensitive account of what resolved, for Diagnostics.
    static var availabilityReport: [DiagnosticEntry] {
        [
            .init(label: "DFRFoundation", value: dfrHandle != nil ? "loaded" : "unavailable"),
            .init(label: "Control Strip presence", value: setControlStripPresence != nil ? "available" : "unavailable"),
            .init(label: "System tray item", value: respondsToTrayItemSelectors() ? "available" : "unavailable"),
            .init(label: "Present system modal", value: presentModal != nil ? "available" : "unavailable"),
            .init(label: "Dismiss system modal", value: dismissModal != nil ? "available" : "unavailable"),
            .init(label: "System modal bridge", value: isSupported ? "supported" : "unsupported"),
        ]
    }

    init(identifier: String) {
        self.identifier = NSTouchBarItem.Identifier(identifier)
    }

    /// Installs the Control Strip item. Idempotent — calling it twice does not
    /// produce duplicate tray items.
    @discardableResult
    func present(view: NSView) -> Bool {
        guard Self.isSupported else {
            log.warning("system modal touch bar unsupported on this system")
            return false
        }
        if let existing = trayItem {
            existing.view = view
            return true
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        trayItem = item

        // `addSystemTrayItem:` takes one object argument, so `perform` is exact
        // here; the multi-argument calls below use typed function pointers.
        _ = (NSTouchBarItem.self as AnyObject).perform(Self.addTrayItemSelector, with: item)
        Self.setControlStripPresence?(identifier.rawValue as NSString, true)
        Self.setShowsCloseBox?(true)

        log.info("control strip item installed")
        return true
    }

    /// Swaps the view shown in the Control Strip without re-registering the item.
    func update(view: NSView) {
        trayItem?.view = view
    }

    /// Shows the expanded detail bar next to the Control Strip.
    func presentModal(_ touchBar: NSTouchBar) {
        guard let (fn, sel) = Self.presentModal else { return }
        fn(NSTouchBar.self, sel, touchBar, Placement.besideControlStrip, identifier.rawValue as NSString)
        presentedBar = touchBar
        isPresentingModal = true
        log.debug("system modal presented")
    }

    /// Returns from the detail bar to the compact Control Strip item.
    func dismissModal() {
        guard isPresentingModal, let bar = presentedBar, let (fn, sel) = Self.dismissModal else { return }
        fn(NSTouchBar.self, sel, bar)
        presentedBar = nil
        isPresentingModal = false
        log.debug("system modal dismissed")
    }

    /// Collapses the modal bar without fully tearing it down.
    func minimizeModal() {
        guard isPresentingModal, let bar = presentedBar, let (fn, sel) = Self.minimizeModal else { return }
        fn(NSTouchBar.self, sel, bar)
        isPresentingModal = false
    }

    /// Removes everything this bridge added. Must run before termination so the
    /// Touch Bar returns to its normal state and a relaunch does not leave a
    /// duplicate tray item behind.
    func dismiss() {
        dismissModal()
        Self.setControlStripPresence?(identifier.rawValue as NSString, false)
        if let item = trayItem, Self.respondsToTrayItemSelectors() {
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.removeTrayItemSelector, with: item)
        }
        trayItem = nil
        log.info("control strip item removed")
    }
}
