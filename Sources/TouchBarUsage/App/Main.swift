import AppKit

/// Entry point. `LSUIElement` in Info.plist keeps the app out of the Dock; the
/// activation policy is set again at launch so `swift run` behaves like the
/// bundled app.
@main
enum Main {
    @MainActor
    static func main() {
        // Development-only: render state previews and exit without touching
        // the Touch Bar, the keychain, or the network.
        if PreviewRenderer.runIfRequested() { return }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)

        // Ctrl-C during development must still remove the Control Strip item,
        // otherwise the Touch Bar keeps a stale widget until the next login.
        installInterruptHandler(delegate: delegate)

        application.run()
    }

    @MainActor
    private static func installInterruptHandler(delegate: AppDelegate) {
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    delegate.tearDown()
                    exit(0)
                }
            }
            source.resume()
            signal(sig, SIG_IGN)
            signalSources.append(source)
        }
    }

    /// Retained for the process lifetime; a released source stops firing.
    @MainActor private static var signalSources: [DispatchSourceSignal] = []
}
