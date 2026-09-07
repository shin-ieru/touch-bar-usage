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

    /// Where a system-modal bar sits relative to the Control Strip.
    ///
    /// This argument is undocumented. Measured directly on macOS 26.6.2 with the
    /// Touch Bar set to `fullControlStrip`:
    ///
    /// - `1` — the bar is displayed, taking the **entire** strip and displacing
    ///   the native volume, brightness and media controls.
    /// - `0` — the native controls remain, but the widget is **not displayed at
    ///   all**.
    ///
    /// So in `fullControlStrip` mode there is no placement that coexists; the
    /// choice is "visible" or "invisible". `1` is therefore the default for the
    /// modal strategy, since an invisible widget is not a product.
    ///
    /// Coexistence is achievable, but through the *other* strategy: with the
    /// Touch Bar set to show app controls, `.controlStripItem` sits beside the
    /// native controls. See docs/touchbar-research.md.
    ///
    /// Override with `TBU_TOUCHBAR_PLACEMENT` to re-measure on a future release.
    private enum Placement {
        static let hiddenInFullControlStrip = 0
        static let fullWidth = 1

        static var configured: Int {
            if let raw = ProcessInfo.processInfo.environment["TBU_TOUCHBAR_PLACEMENT"],
               let value = Int(raw) {
                return value
            }
            return fullWidth
        }
    }

    /// How the widget reaches the physical bar.
    ///
    /// Which one works depends on the user's "Touch Bar shows" setting, so the
    /// choice is made at runtime rather than baked in.
    enum Strategy: String {
        /// Register a Control Strip item that sits beside the native controls.
        /// This would be the least invasive option, but on macOS 26.6.2 the item
        /// is never drawn even though registration succeeds. Retained behind
        /// `TBU_TOUCHBAR_STRATEGY` so it can be re-measured on future releases.
        case controlStripItem

        /// Present a persistent system-modal bar. Verified to display on macOS
        /// 26.6.2, but it claims the full strip, so the native controls are not
        /// visible while it is presented.
        case persistentModal

        /// Present the system-modal bar and immediately minimise it, in the hope
        /// of collapsing to a tray item beside the native controls. Measured on
        /// macOS 26.6.2: the widget disappears entirely — minimising collapses to
        /// nothing, because the tray item is not rendered. Kept for re-measurement
        /// on future releases.
        case minimizedModal
    }

    private let identifier: NSTouchBarItem.Identifier
    private let log = Log(category: "touchbar-bridge")

    private var trayItem: NSCustomTouchBarItem?
    private var presentedBar: NSTouchBar?
    private(set) var isPresentingModal = false

    /// Retained bar and delegate for the persistent-modal strategy.
    private var compactBar: NSTouchBar?
    private var compactProvider: CompactBarProvider?
    private var compactModalItemIdentifier: NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(identifier.rawValue + ".compact")
    }

    /// Returns to the compact widget after the detail bar is dismissed. Only
    /// meaningful under `.persistentModal`, where nothing else would be showing.
    func restoreCompactPresentation() {
        guard let bar = compactBar else { return }
        switch strategy {
        case .controlStripItem:
            break
        case .persistentModal:
            presentModal(bar)
        case .minimizedModal:
            presentModal(bar)
            minimizeModal()
        }
    }

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
            .init(label: "Touch Bar shows", value: presentationMode),
            .init(label: "Presentation strategy", value: recommendedStrategy.rawValue),
        ]
    }

    /// The user's `Touch Bar shows:` setting. `fullControlStrip` means the
    /// expanded Control Strip owns the entire bar and app items are never shown.
    static var presentationMode: String {
        (CFPreferencesCopyAppValue("PresentationModeGlobal" as CFString,
                                   "com.apple.touchbar.agent" as CFString) as? String)
            ?? "unknown"
    }

    /// Chosen per launch. An override exists for re-testing the other path by
    /// hand on a future macOS release.
    ///
    /// `.persistentModal` is the default because it is the **only** strategy
    /// measured to actually display on macOS 26.6.2.
    ///
    /// `.controlStripItem` registers successfully — every call returns without
    /// error — but the item is never drawn, in either `fullControlStrip` or `app`
    /// presentation mode, collapsed or expanded. `.minimizedModal` collapses to
    /// nothing for the same reason. Third-party Control Strip items appear to be
    /// no longer honoured on this OS version.
    ///
    /// The consequence is a real tradeoff: the modal bar claims the full strip,
    /// so the native volume, brightness and media controls are not visible while
    /// it is presented. The menu bar's "Touch Bar: On/Off" toggle is the escape
    /// hatch. See docs/touchbar-research.md.
    static var recommendedStrategy: Strategy {
        if let forced = ProcessInfo.processInfo.environment["TBU_TOUCHBAR_STRATEGY"],
           let strategy = Strategy(rawValue: forced) {
            return strategy
        }
        return .persistentModal
    }

    private(set) var strategy: Strategy = .controlStripItem

    init(identifier: String) {
        self.identifier = NSTouchBarItem.Identifier(identifier)
    }

    /// Installs the widget using whichever strategy suits the current Touch Bar
    /// setting. Idempotent — calling it twice does not produce duplicate items.
    @discardableResult
    func present(view: NSView) -> Bool {
        guard Self.isSupported else {
            log.warning("system modal touch bar unsupported on this system")
            return false
        }
        strategy = Self.recommendedStrategy

        if let existing = trayItem {
            existing.view = view
        } else {
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = view
            trayItem = item

            // `addSystemTrayItem:` takes one object argument, so `perform` is
            // exact here; the multi-argument calls use typed function pointers.
            // The tray item is registered under both strategies: it is what gives
            // the modal bar an anchor identifier to sit beside.
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.addTrayItemSelector, with: item)
            Self.setControlStripPresence?(identifier.rawValue as NSString, true)
            Self.setShowsCloseBox?(true)
        }

        switch strategy {
        case .controlStripItem:
            break   // registration only; see the strategy docs
        case .persistentModal:
            presentCompactModal(view: view)
        case .minimizedModal:
            // Present, then collapse straight back to the tray item so the
            // native controls stay on screen.
            presentCompactModal(view: view)
            minimizeModal()
        }

        log.info("touch bar widget installed", [
            "strategy": strategy.rawValue,
            "presentationMode": Self.presentationMode,
        ])
        return true
    }

    /// Wraps the compact view in a bar and presents it beside the Control Strip.
    /// Used when app-provided Control Strip items would not be displayed.
    private func presentCompactModal(view: NSView) {
        let bar = NSTouchBar()
        let holder = CompactBarProvider(identifier: compactModalItemIdentifier, view: view)
        compactProvider = holder
        bar.delegate = holder
        bar.defaultItemIdentifiers = [compactModalItemIdentifier]
        compactBar = bar
        presentModal(bar)
    }

    /// Swaps the view shown in the widget without re-registering anything.
    func update(view: NSView) {
        trayItem?.view = view
        compactProvider?.view = view
    }

    /// Shows the expanded detail bar next to the Control Strip.
    func presentModal(_ touchBar: NSTouchBar) {
        guard let (fn, sel) = Self.presentModal else { return }
        fn(NSTouchBar.self, sel, touchBar, Placement.configured, identifier.rawValue as NSString)
        presentedBar = touchBar
        isPresentingModal = true
        log.debug("system modal presented", ["placement": "\(Placement.configured)"])
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
        if let bar = compactBar, let (fn, sel) = Self.dismissModal {
            fn(NSTouchBar.self, sel, bar)
        }
        compactBar = nil
        compactProvider = nil
        Self.setControlStripPresence?(identifier.rawValue as NSString, false)
        if let item = trayItem, Self.respondsToTrayItemSelectors() {
            _ = (NSTouchBarItem.self as AnyObject).perform(Self.removeTrayItemSelector, with: item)
        }
        trayItem = nil
        log.info("control strip item removed")
    }
}


/// Holds the compact view for the persistent-modal strategy. A separate object
/// because `NSTouchBar.delegate` is weak and the bridge is not an NSObject.
private final class CompactBarProvider: NSObject, NSTouchBarDelegate {
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
