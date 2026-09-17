import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ClickThroughController?
    private var statusBar: StatusBarController?
    private var accessibility: AccessibilityManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        // Launch at login is part of what this utility is, not a preference.
        LoginItemManager.registerIfNeeded()

        let accessibility = AccessibilityManager()
        let controller = ClickThroughController()
        let statusBar = StatusBarController(controller: controller, accessibility: accessibility)

        controller.onStateChanged = { [weak statusBar] in statusBar?.update() }
        accessibility.onTrustChanged = { [weak controller, weak statusBar] in
            controller?.syncTapState()
            statusBar?.update()
        }

        self.accessibility = accessibility
        self.controller = controller
        self.statusBar = statusBar

        // Let macOS ask for Accessibility permission in its own words, once.
        accessibility.promptIfNeeded()
        accessibility.startMonitoring()
        controller.syncTapState()
        statusBar.update()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller = nil    // stops the tap and removes observers
    }

    /// A login item plus a manual launch can race. The instance that is already
    /// running wins; this one exits silently.
    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID }
        guard !others.isEmpty else { return false }
        Log.app.info("Another instance is already running; exiting")
        NSApp.terminate(nil)
        return true
    }
}
