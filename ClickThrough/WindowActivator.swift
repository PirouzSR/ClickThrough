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

    /// Activates `pid`, optionally making the specific clicked window the front
    /// window of that application first, and waits for the activation to take
    /// effect before returning.
    ///
    /// The caller then returns the original `CGEvent` unmodified, so the target
    /// receives the user's actual click - no synthetic event is ever generated.
    static func activate(pid: pid_t, windowBounds: CGRect, raiseWindow: Bool) {
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

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)

        // Raise before activating. Activation brings an application's windows
        // forward as a group, so raising first guarantees the window the user
        // actually clicked ends up on top - and becomes key - rather than
        // whichever window of that app happened to be in front.
        if raiseWindow {
            raise(windowWithBounds: windowBounds, in: element, deadline: deadline)
        }

        if !app.activate(options: []) {
            // Rare: the request was refused. Fall back to asking the application
            // itself, via Accessibility, to come to the front.
            let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Log.debug("activate: NSRunningApplication refused, AXFrontmost -> \(result.rawValue)")
        }

        waitUntilFrontmost(element, deadline: deadline)
    }

    /// Blocks until the target application reports that it is frontmost, or the
    /// budget runs out.
    ///
    /// This is the difference between the click landing and being swallowed.
    /// `activate` only *requests* activation; if the held mouse-down is released
    /// before the application has actually become active, AppKit still treats it
    /// as the click that activates the window and discards it. The race is easy
    /// to lose when the window is on a second display, where activation is
    /// measurably slower.
    private static func waitUntilFrontmost(_ element: AXUIElement, deadline: CFTimeInterval) {
        while CFAbsoluteTimeGetCurrent() < deadline {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value) == .success,
               (value as? Bool) == true {
                return
            }
            usleep(confirmationPollInterval)
        }
        Log.debug("activate: target did not report frontmost within budget")
    }

    /// Finds the target application's Accessibility window whose frame matches the
    /// window-server bounds, and raises it.
    ///
    /// Frame matching is used because the public Accessibility API exposes no
    /// window identifier. (`_AXUIElementGetWindow` would provide one directly but
    /// it is private SPI, which this app deliberately avoids.)
    private static func raise(windowWithBounds bounds: CGRect, in app: AXUIElement, deadline: CFTimeInterval) {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return }

        // Single-window applications need no matching at all.
        if windows.count == 1 {
            AXUIElementPerformAction(windows[0], kAXRaiseAction as CFString)
            return
        }

        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        for window in windows {
            // A busy application answers slowly; with many windows the search
            // alone could outlast the tap timeout, so give up and settle for
            // activating the application.
            guard CFAbsoluteTimeGetCurrent() < deadline else {
                Log.debug("activate: window search ran out of budget")
                return
            }
            var values: CFArray?
            // One round trip per window instead of two.
            guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let pair = values as? [AnyObject], pair.count == 2,
                  CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID()
            else { continue }

            var origin = CGPoint.zero
            var size = CGSize.zero
            // Safe: the CFGetTypeID checks above confirmed both are AXValues.
            AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin)
            AXValueGetValue(pair[1] as! AXValue, .cgSize, &size)

            if abs(origin.x - bounds.minX) <= frameMatchTolerance,
               abs(origin.y - bounds.minY) <= frameMatchTolerance,
               abs(size.width - bounds.width) <= frameMatchTolerance,
               abs(size.height - bounds.height) <= frameMatchTolerance {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }
}
