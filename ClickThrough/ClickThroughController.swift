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

    /// How long the utility may stay dead after the system disables the tap.
    private static let watchdogInterval: TimeInterval = 1

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

        // Pay the window-server and Dock connection setup costs now rather than
        // on the user's first click.
        WindowFinder.warmUp()
        DockInspector.warmUp()
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

        // Read the window list at most once, and only if the policy asks for it:
        // that read is a round trip to the window server and is essentially the
        // whole cost of handling a click.
        var fetched: [WindowSnapshot]?
        let windows = { () -> [WindowSnapshot] in
            if let fetched { return fetched }
            let list = WindowFinder.onScreenWindows()
            fetched = list
            return list
        }

        let action = WindowFinder.action(for: event.location,
                                         windows: windows,
                                         frontmostPID: snapshot.frontmostPID,
                                         frontmostIsSystemUI: snapshot.frontmostIsSystemUI,
                                         screens: snapshot.screens,
                                         ownPID: ownPID,
                                         modifiers: event.flags,
                                         dockState: DockInspector.state)

        switch action {
        case .ignore(let reason):
            Log.debug("ignore(\(reason.rawValue)) at \(event.location)")
        case .activate(let pid, let windowID, let bounds, let raiseWindow):
            Log.debug("activate pid=\(pid) window=\(windowID) raise=\(raiseWindow) at \(event.location)")
            WindowActivator.activate(pid: pid, windowBounds: bounds, raiseWindow: raiseWindow,
                                     windows: fetched ?? [], displays: snapshot.screens.map(\.frame))
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

        // Belt and braces, and the only thing that recovers two failure modes
        // that would otherwise leave the utility silently dead: a tap the system
        // disabled without the callback ever being told, and a tap that could not
        // be created at all - which happens if the app starts before the window
        // server session is ready, as it can at login.
        //
        // Measured on macOS: the window server disables a tap whose callback
        // takes longer than about a second, and delivers the disabled event only
        // when the *next* event is routed. So a tap can sit disabled with no
        // callback coming, and the interval here is exactly how long the utility
        // stays dead when that happens. `CGEvent.tapIsEnabled` is a cheap query
        // and the tolerance lets the system coalesce the wake-up, so checking
        // every second costs effectively nothing.
        let watchdog = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tap?.reenableIfNeeded()
            if self.isEnabled, self.tap?.isRunning == false {
                self.syncTapState()
            }
        }
        watchdog.tolerance = Self.watchdogInterval
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
