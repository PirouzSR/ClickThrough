import AppKit
import ApplicationServices

/// What the Dock is doing at the moment of a click.
struct DockState: Equatable {
    /// The strip the Dock occupies on screen, in Core Graphics global
    /// coordinates. Off-screen - and so containing nothing - while the Dock is
    /// hidden, which is how automatic hiding is handled without a special case.
    let strip: CGRect
    /// True while a stack - the fan or grid from a folder in the Dock - is open.
    let showsStack: Bool
}

/// Asks the Dock what it is showing.
///
/// Everything the Dock draws - the strip of icons and any open stack - lives in
/// a single window that covers the whole display, and the Dock does not become
/// the frontmost application for either. So none of the signals this utility
/// normally uses can tell a click on the Dock from a click on the window behind
/// it: the window level says "backdrop", which the backdrop rule deliberately
/// looks past, and the frontmost application is still whatever the user was
/// using. Asking the Dock directly is the only way.
///
/// Measured on macOS:
///
/// - the Dock's first Accessibility child is the list of its items, and that
///   list's frame is the strip the Dock really occupies. It follows the Dock to
///   the left or right edge, grows with the icon size, and sits below the bottom
///   of the display while the Dock is auto-hidden;
/// - while a stack is open the Dock reports a focused element - the stack's list
///   - and reports none when no stack is open.
///
/// Two round trips, ~0.2 ms once warm, and only ever on a click that would
/// otherwise activate something.
enum DockInspector {
    /// Upper bound on each round trip, for the same reason as in
    /// `WindowActivator`: nothing on the event-tap thread may stall the mouse.
    private static let messagingTimeout: Float = 0.05

    /// Only used by `warmUp()`; the hot path takes the Dock's process identifier
    /// from the window list instead.
    private static let dockBundleID = "com.apple.dock"

    /// - Parameter pid: the Dock, taken from the window list rather than looked
    ///   up by bundle identifier. That costs nothing on the hot path and stays
    ///   correct if the Dock is restarted.
    /// - Returns: `nil` when the Dock does not answer, so the caller can fall
    ///   back rather than treat silence as "the Dock is not involved".
    static func state(pid: pid_t) -> DockState? {
        let dock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(dock, messagingTimeout)

        var values: CFArray?
        let wanted = [kAXFocusedUIElementAttribute, kAXChildrenAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(dock, wanted, [], &values) == .success,
              let pair = values as? [AnyObject], pair.count == 2
        else { return nil }

        // A focused element means a stack is being tracked. When there is none
        // the entry is an error value rather than an element.
        let showsStack = CFGetTypeID(pair[0]) == AXUIElementGetTypeID()

        guard let children = pair[1] as? [AXUIElement], let items = children.first else {
            return DockState(strip: .null, showsStack: showsStack)
        }
        return DockState(strip: frame(of: items) ?? .null, showsStack: showsStack)
    }

    /// The first Accessibility round trip to a process costs ~25 ms while the
    /// connection is established. Pay that at launch rather than on the user's
    /// first click, exactly as `WindowFinder.warmUp()` does for the window server.
    static func warmUp() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first
        else { return }
        _ = state(pid: dock.processIdentifier)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let wanted = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, wanted, [], &values) == .success,
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
}
