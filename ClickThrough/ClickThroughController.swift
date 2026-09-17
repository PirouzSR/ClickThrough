import AppKit
import os

/// Owns the event tap and the small amount of state its hot path needs.
///
/// Everything expensive - watching for application switches, display changes and
/// wake - happens on the main thread and is published into a lock-protected
/// snapshot, so handling a click costs one window-list query and nothing else.
final class ClickThroughController: @unchecked Sendable {
    private struct Environment {
        var frontmostPID: pid_t = -1
        var frontmostIsSystemUI = false
        var screens: [ScreenInfo] = []
    }

    private static let enabledDefaultsKey = "ClickThroughEnabled"

    private let environment = OSAllocatedUnfairLock(initialState: Environment())
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var tap: EventTap?
    private var watchdog: Timer?

    /// Called on the main thread whenever the menu bar presentation should change.
    var onStateChanged: (() -> Void)?

    /// User preference. Defaults to on, and persists across launches.
    private(set) var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey) }
    }

    /// True when clicks are actually being intercepted right now. This is false
    /// when the user has switched the utility off *or* when Accessibility
    /// permission has not been granted.
    var isActive: Bool { tap?.isRunning ?? false }

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)

        tap = EventTap { [weak self] event in self?.handleMouseDown(event) }

        refreshFrontmostApplication()
        refreshScreens()
        observeSystemChanges()

        // Pay the window-server connection setup cost now rather than on the
        // user's first click (~50 ms the first time, ~2 ms thereafter).
        WindowFinder.warmUp()
    }

    deinit {
        watchdog?.invalidate()
        tap?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Enablement

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        syncTapState()
    }

    /// Starts or stops the tap so that it matches the user preference and the
    /// current Accessibility permission. Safe to call repeatedly.
    func syncTapState() {
        guard let tap else { return }
        if isEnabled && AXIsProcessTrusted() {
            if !tap.isRunning {
                // Re-creating on each transition also covers the case where
                // permission was granted after launch.
                _ = tap.start()
            }
        } else if tap.isRunning {
            tap.stop()
        }
        onStateChanged?()
    }

    // MARK: - Hot path (event-tap thread)

    private func handleMouseDown(_ event: CGEvent) {
        let snapshot = environment.withLock { $0 }
        let action = WindowFinder.action(for: event.location,
                                         windows: WindowFinder.onScreenWindows(),
                                         frontmostPID: snapshot.frontmostPID,
                                         frontmostIsSystemUI: snapshot.frontmostIsSystemUI,
                                         screens: snapshot.screens,
                                         ownPID: ownPID,
                                         modifiers: event.flags)

        switch action {
        case .ignore(let reason):
            Log.debug("ignore(\(reason.rawValue)) at \(event.location)")
        case .activate(let pid, let windowID, let bounds, let raiseWindow):
            Log.debug("activate pid=\(pid) window=\(windowID) raise=\(raiseWindow) at \(event.location)")
            WindowActivator.activate(pid: pid, windowBounds: bounds, raiseWindow: raiseWindow)
        }
        // The caller returns the original event either way.
    }

    // MARK: - Environment tracking (main thread)

    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationActivated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake(_:)),
                              name: NSWorkspace.didWakeNotification, object: nil)
        // Display added/removed/rearranged, resolution or scaling change.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Belt and braces: taps can also be disabled without the tap thread being
        // told, for example around some system UI transitions.
        let watchdog = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.tap?.reenableIfNeeded()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    @objc private func applicationActivated(_ note: Notification) {
        refreshFrontmostApplication(
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    @objc private func systemDidWake(_ note: Notification) {
        tap?.reenableIfNeeded()
        refreshScreens()
    }

    @objc private func screensChanged(_ note: Notification) {
        refreshScreens()
    }

    private func refreshFrontmostApplication(_ application: NSRunningApplication? = nil) {
        let app = application ?? NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? -1
        let isSystemUI = app?.bundleIdentifier.map(WindowFinder.systemUIBundleIDs.contains) ?? false
        environment.withLock {
            $0.frontmostPID = pid
            $0.frontmostIsSystemUI = isSystemUI
        }
    }

    private func refreshScreens() {
        let screens = ScreenGeometry.current()
        environment.withLock { $0.screens = screens }
    }
}
