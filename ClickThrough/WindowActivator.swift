import AppKit
import ApplicationServices

/// Brings a clicked window's application forward.
///
/// Called from the event-tap thread while the original mouse-down is held, so
/// every call here is bounded: a hung target application must never be able to
/// stall the user's mouse.
enum WindowActivator {
    /// Upper bound on how long any single Accessibility round trip to another
    /// process may take. Well under the event tap's own one-second budget.
    private static let axMessagingTimeout: Float = 0.1

    /// Tolerance when pairing an Accessibility window with a window-server window.
    /// Measured on macOS: `kAXPosition`/`kAXSize` and `kCGWindowBounds` agree
    /// exactly for standard windows, so this only absorbs rounding.
    private static let frameMatchTolerance: CGFloat = 2

    /// Activates `pid`, optionally making the specific clicked window the front
    /// window of that application first.
    ///
    /// The caller then returns the original `CGEvent` unmodified, so the target
    /// receives the user's actual click - no synthetic event is ever generated.
    static func activate(pid: pid_t, windowBounds: CGRect, raiseWindow: Bool) {
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

        // Raise before activating. Activation brings an application's windows
        // forward as a group, so raising first guarantees the window the user
        // actually clicked ends up on top - and becomes key - rather than
        // whichever window of that app happened to be in front.
        if raiseWindow {
            raise(windowWithBounds: windowBounds, pid: pid)
        }

        if !app.activate(options: []) {
            // Rare: the request was refused. Fall back to asking the application
            // itself, via Accessibility, to come to the front.
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Log.debug("activate: NSRunningApplication refused, AXFrontmost -> \(result.rawValue)")
        }
    }

    /// Finds the target application's Accessibility window whose frame matches the
    /// window-server bounds, and raises it.
    ///
    /// Frame matching is used because the public Accessibility API exposes no
    /// window identifier. (`_AXUIElementGetWindow` would provide one directly but
    /// it is private SPI, which this app deliberately avoids.)
    private static func raise(windowWithBounds bounds: CGRect, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)

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
