import AppKit
import ApplicationServices

/// Brings a clicked window's application forward.
///
/// Called from the event-tap thread while the original mouse-down is held, so
/// everything here is bounded: a hung target application must never be able to
/// stall the user's mouse, and the whole callback must stay well inside the
/// event tap's own one-second budget or macOS disables the tap.
enum WindowActivator {
    /// Upper bound on any single Accessibility round trip to another process.
    private static let axMessagingTimeout: Float = 0.05

    /// Total time the tap may spend activating, including waiting for the
    /// activation to take effect. Generous enough for a slow application to
    /// come forward, far short of the tap timeout.
    private static let activationBudget: CFTimeInterval = 0.2

    /// How often to ask the target whether it has become frontmost yet.
    private static let confirmationPollInterval: useconds_t = 2_000

    /// Tolerance when pairing an Accessibility window with a window-server window.
    /// Measured on macOS: `kAXPosition`/`kAXSize` and `kCGWindowBounds` agree
    /// exactly for standard windows, so this only absorbs rounding.
    private static let frameMatchTolerance: CGFloat = 2

    /// A window that was on top of its display before an activation, so that it
    /// can be put back if the activation displaced it.
    struct DisplacedWindow: Sendable {
        let pid: pid_t
        let bounds: CGRect
    }

    /// Queue used to put displaced windows back, off the event-tap thread.
    private static let restoreQueue = DispatchQueue(label: "com.clickthrough.restore",
                                                    qos: .userInitiated)

    /// When to retry putting a displaced window back. An application raises its
    /// own last-used window slightly *after* it is activated, so a single
    /// immediate attempt loses the race; these were measured to be enough.
    private static let restoreDelays: [DispatchTimeInterval] =
        [.milliseconds(40), .milliseconds(130), .milliseconds(310)]

    /// Activates `pid`, makes the specific clicked window the one the application
    /// has focused, and waits for that to take effect before returning.
    ///
    /// The caller then returns the original `CGEvent` unmodified, so the target
    /// receives the user's actual click - no synthetic event is ever generated.
    ///
    /// - Parameters:
    ///   - windows: the on-screen window list already read for the click, used to
    ///     notice windows on *other* displays that activation may displace.
    ///   - displays: current display frames.
    static func activate(pid: pid_t, windowBounds: CGRect, raiseWindow: Bool,
                         windows: [WindowSnapshot], displays: [CGRect]) {
        let deadline = CFAbsoluteTimeGetCurrent() + activationBudget

        // The window may have belonged to a process that has since exited.
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            Log.debug("activate: pid \(pid) no longer running")
            return
        }
        // Agents and UI-less helpers cannot be activated; asking would be a no-op.
        guard app.activationPolicy != .prohibited else {
            Log.debug("activate: pid \(pid) has prohibited activation policy")
            return
        }

        let displaced = windowsActivationWouldDisplace(targetPID: pid, clicked: windowBounds,
                                                       windows: windows, displays: displays)

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)

        // The clicked window has to be raised twice: once before activating, so
        // that it is the window activation brings forward, and once after,
        // because activation makes the application focus and raise *its own*
        // last-used window and throw the first raise away. Measured on macOS
        // with a browser holding a window on each display: without the second
        // raise the clicked window is not the focused one when the mouse-down is
        // released and the click is swallowed exactly as if this utility were
        // not running - 0 clicks delivered out of 8, against 8 out of 8 with it.
        //
        // Finding the window costs an Accessibility round trip per window of
        // that application, so it is found once and reused rather than searched
        // for twice: that took the time spent here from 34-37 ms to 19-22 ms for
        // a browser with two windows. Reusing the element is also more accurate,
        // because an element keeps referring to the same window even if it moves.
        let target = raiseWindow ? window(matching: windowBounds, in: element, deadline: deadline) : nil
        if let target { AXUIElementPerformAction(target, kAXRaiseAction as CFString) }

        if !app.activate(options: []) {
            // Rare: the request was refused. Fall back to asking the application
            // itself, via Accessibility, to come to the front.
            let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Log.debug("activate: NSRunningApplication refused, AXFrontmost -> \(result.rawValue)")
        }

        if let target { AXUIElementPerformAction(target, kAXRaiseAction as CFString) }

        waitUntilReady(element, windowBounds: windowBounds, deadline: deadline)
        restore(displaced)
    }

    /// Windows that activating `targetPID` is likely to cover up, and should not.
    ///
    /// Activating an application raises its windows on *every* display, not just
    /// the one being clicked. On a second display that means a window the user
    /// was working in - an editor, say - suddenly disappears behind a window of
    /// the application they clicked on the other screen. Nothing about the click
    /// asked for that, and stock macOS does not do it: it simply discards the
    /// click instead.
    ///
    /// Only the top-most window of each *other* display is considered, and only
    /// when it belongs to some other application and the target actually has a
    /// window on that display to be raised over it.
    private static func windowsActivationWouldDisplace(targetPID: pid_t, clicked: CGRect,
                                                       windows: [WindowSnapshot],
                                                       displays: [CGRect]) -> [DisplacedWindow] {
        let clickedDisplay = displays.first { $0.intersects(clicked) }
        var result: [DisplacedWindow] = []
        for display in displays where display != clickedDisplay {
            let onThisDisplay = windows.filter { $0.layer == 0 && $0.alpha > 0 && display.intersects($0.bounds) }
            guard let top = onThisDisplay.first, top.pid != targetPID,
                  onThisDisplay.contains(where: { $0.pid == targetPID })
            else { continue }
            result.append(DisplacedWindow(pid: top.pid, bounds: top.bounds))
        }
        return result
    }

    /// Puts displaced windows back on top of their own display.
    ///
    /// Raising a window does not change which application is active - verified -
    /// so this does not undo the activation that the click depends on. It runs
    /// once immediately and again a few times shortly afterwards, because the
    /// application does its own raising just after being activated.
    private static func restore(_ displaced: [DisplacedWindow]) {
        guard !displaced.isEmpty else { return }
        raiseEach(displaced)
        var elapsed = DispatchTime.now()
        for delay in restoreDelays {
            elapsed = elapsed + delay
            restoreQueue.asyncAfter(deadline: elapsed) { raiseEach(displaced) }
        }
    }

    private static func raiseEach(_ displaced: [DisplacedWindow]) {
        for window in displaced {
            let app = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
            if let w = self.window(matching: window.bounds, in: app,
                                   deadline: CFAbsoluteTimeGetCurrent() + activationBudget) {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
        }
    }

    /// Blocks until the application is frontmost *and* the clicked window is the
    /// one it has focused, or the budget runs out.
    ///
    /// This is the difference between the click landing and being swallowed.
    /// `activate` only *requests* activation; if the held mouse-down is released
    /// before the application has actually become active, AppKit still treats it
    /// as the click that activates the window and discards it. The race is easy
    /// to lose when the window is on a second display, where activation is
    /// measurably slower.
    ///
    /// Waiting for `kAXFrontmost` alone is not enough, and that is what made this
    /// fail for a browser with a window on each display. `kAXFrontmost` goes true
    /// while the application is still settling, and an application activated from
    /// the background focuses *its own* idea of the front window first - which,
    /// for a browser, is whichever window was last used, not the one just
    /// clicked. Releasing the mouse-down then delivers it to a window that is not
    /// focused, and it is swallowed exactly as before. Measured on macOS: waiting
    /// only for frontmost delivered 0 clicks out of 8 in that setup.
    private static func waitUntilReady(_ element: AXUIElement, windowBounds: CGRect,
                                       deadline: CFTimeInterval) {
        var sawFrontmost = false
        while CFAbsoluteTimeGetCurrent() < deadline {
            if !sawFrontmost {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value) == .success,
                   (value as? Bool) == true {
                    sawFrontmost = true
                }
            }
            if sawFrontmost, focusedWindowMatches(windowBounds, in: element) { return }
            usleep(confirmationPollInterval)
        }
        Log.debug("activate: target not ready within budget (frontmost: \(sawFrontmost))")
    }

    /// True when the application's focused window is the one that was clicked.
    private static func focusedWindowMatches(_ bounds: CGRect, in app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return false }
        guard let frame = frame(of: window as! AXUIElement) else { return false }
        return abs(frame.minX - bounds.minX) <= frameMatchTolerance
            && abs(frame.minY - bounds.minY) <= frameMatchTolerance
            && abs(frame.width - bounds.width) <= frameMatchTolerance
            && abs(frame.height - bounds.height) <= frameMatchTolerance
    }

    /// An Accessibility window's frame, in one round trip.
    private static func frame(of window: AXUIElement) -> CGRect? {
        var values: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
              let pair = values as? [AnyObject], pair.count == 2,
              CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID()
        else { return nil }
        let position = pair[0] as! AXValue
        let size = pair[1] as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// The target application's Accessibility window whose frame matches the
    /// window-server bounds.
    ///
    /// Frame matching is used because the public Accessibility API exposes no
    /// window identifier. (`_AXUIElementGetWindow` would provide one directly but
    /// it is private SPI, which this app deliberately avoids.)
    private static func window(matching bounds: CGRect, in app: AXUIElement,
                               deadline: CFTimeInterval) -> AXUIElement? {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return nil }

        // Single-window applications need no matching at all.
        if windows.count == 1 { return windows[0] }

        for window in windows {
            // A busy application answers slowly; with many windows the search
            // alone could outlast the tap timeout, so give up and settle for
            // activating the application.
            guard CFAbsoluteTimeGetCurrent() < deadline else {
                Log.debug("activate: window search ran out of budget")
                return nil
            }
            // One round trip per window instead of two.
            guard let r = frame(of: window) else { continue }

            if abs(r.minX - bounds.minX) <= frameMatchTolerance,
               abs(r.minY - bounds.minY) <= frameMatchTolerance,
               abs(r.width - bounds.width) <= frameMatchTolerance,
               abs(r.height - bounds.height) <= frameMatchTolerance {
                return window
            }
        }
        return nil
    }
}
