import AppKit
import ApplicationServices

/// Asks Notification Center where it is drawing right now.
///
/// Notification Center has exactly the problem the Dock has: a banner, and the
/// whole notification panel, are drawn into a single window that covers the
/// entire display, and Notification Center never becomes the frontmost
/// application. `WindowFinder` deliberately looks past a window like that -
/// otherwise the Dock's permanent one would swallow every click - so without
/// asking, a click on a notification, and in particular on the close button that
/// appears when the pointer is over one, reaches the window behind it and brings
/// that window forward instead of dismissing the notification.
///
/// Measured on macOS 27. Inside that window the banners sit under a scroll area,
/// wrapped in groups that carry no subrole and draw nothing of their own:
///
///     AXWindow/AXSystemDialog                      the whole display
///       AXGroup/AXHostingView                      the whole display
///         AXGroup                                  the region banners live in
///           AXScrollArea
///             AXGroup/AXNotificationCenterBanner   one notification
///
/// and with the panel open that scroll area holds the notification list and its
/// buttons instead. Rather than hard-code that path, this walks it by shape:
/// descend through the containers - anything filling the window, any scroll
/// area, any group with no subrole - and take the first thing on each branch
/// that occupies a place of its own. A click inside one of those rectangles
/// belongs to Notification Center. Anywhere else in the window does not, and is
/// left to the window underneath, which is what makes this safe: the worst a
/// hierarchy this code fails to recognise can do is leave a click alone.
///
/// No title, description or value is ever read. The walk needs geometry, and
/// notification text is exactly the kind of content this utility stays out of.
enum NotificationCenterInspector {
    /// Upper bound on each round trip, for the same reason as in `DockInspector`:
    /// nothing on the event-tap thread may stall the user's mouse.
    private static let messagingTimeout: Float = 0.05

    /// Only used by `warmUp()`; the hot path takes the process identifier from
    /// the window list.
    private static let bundleID = "com.apple.notificationcenterui"

    /// Bounds on the walk, so that an unfamiliar hierarchy costs a fixed number
    /// of round trips instead of an open-ended search. The banners observed sit
    /// at depth 4.
    private static let maxDepth = 6
    private static let maxRects = 32

    /// Tolerance when pairing the Accessibility window with the window-server
    /// window, and when deciding that something fills that window. Measured on
    /// macOS: the two agree exactly, so this only absorbs rounding.
    private static let frameTolerance: CGFloat = 2

    /// The rectangles Notification Center is currently drawing content in.
    ///
    /// - Parameters:
    ///   - pid: Notification Center, taken from the window list rather than
    ///     looked up by bundle identifier, which costs nothing on the hot path
    ///     and stays correct if it is restarted.
    ///   - window: bounds of its full-display window, taken from the window
    ///     list, used to find the matching Accessibility window.
    /// - Returns: empty when it does not answer, or is drawing nothing that can
    ///   be clicked, which leaves the click to the ordinary rules.
    static func contentRects(pid: pid_t, window: CGRect) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        // The window's own frame is carried down rather than the window-server
        // bounds it was matched against, so that the comparisons below are
        // against numbers from the same source.
        var root: (element: AXUIElement, frame: CGRect)?
        for candidate in elements(of: app, attribute: kAXWindowsAttribute) ?? [] {
            guard let frame = candidate.frame,
                  frame.insetBy(dx: -frameTolerance, dy: -frameTolerance).contains(window)
            else { continue }
            root = (candidate, frame)
            break
        }
        guard let root else { return [] }

        var rects: [CGRect] = []
        collect(root.element, window: root.frame, depth: 0, into: &rects)
        return rects
    }

    /// The first Accessibility round trip to a process costs ~25 ms while the
    /// connection is established. Pay that at launch rather than on a click, as
    /// `DockInspector.warmUp()` does.
    static func warmUp() {
        guard let centre = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        // Nothing matches an empty rectangle, so this pays the cost of setting
        // the connection up and then finds nothing to walk.
        _ = contentRects(pid: centre.processIdentifier, window: .null)
    }

    private static func collect(_ element: AXUIElement, window: CGRect, depth: Int,
                                into rects: inout [CGRect]) {
        guard rects.count < maxRects, let rect = element.frame, !rect.isEmpty else { return }

        guard !isContainer(element, rect: rect, window: window) else {
            // A container draws nothing itself, so look inside it. Giving up at
            // the depth limit rather than falling back to the container's own
            // rectangle keeps the worst case "this click is left alone", never
            // "every click in this whole region is".
            guard depth < maxDepth else { return }
            for child in elements(of: element, attribute: kAXChildrenAttribute) ?? [] {
                collect(child, window: window, depth: depth + 1, into: &rects)
            }
            return
        }
        rects.append(rect)
    }

    /// True for the parts of the hierarchy that only hold other parts: the window
    /// and any view filling it, the scroll area the banners are laid out in, and
    /// the anonymous groups in between. A group *with* a subrole is a banner -
    /// content, not a container.
    private static func isContainer(_ element: AXUIElement, rect: CGRect, window: CGRect) -> Bool {
        // Anything filling the window, whatever its role says it is. A rectangle
        // the size of the display cannot be something the user clicked, and
        // returning one would leave the utility ignoring every click on that
        // display for as long as Notification Center has anything on screen.
        if rect.insetBy(dx: -frameTolerance, dy: -frameTolerance).contains(window) { return true }
        switch string(of: element, attribute: kAXRoleAttribute) {
        case kAXScrollAreaRole: return true
        case kAXGroupRole: return string(of: element, attribute: kAXSubroleAttribute) == nil
        default: return false
        }
    }

    private static func elements(of element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? [AXUIElement]
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
