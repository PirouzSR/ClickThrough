import AppKit

/// One display, expressed in Core Graphics global coordinates.
///
/// Every geometric comparison in this app happens in CG coordinates: the origin
/// is the top-left of the primary display and y grows downward. `CGEvent.location`
/// and `kCGWindowBounds` both use that space, so no per-display conversion or
/// backing-scale maths is needed - which is what makes mixed-resolution and
/// mixed-scaling multi-monitor setups work without special cases.
struct ScreenInfo: Equatable {
    /// Full display bounds.
    let frame: CGRect
    /// Display bounds minus the menu bar and the Dock.
    let visibleFrame: CGRect
}

enum ScreenGeometry {
    /// Snapshots the current display layout. Must be called on the main thread;
    /// the result is an immutable value safe to read from the event-tap thread.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        // NSScreen uses a bottom-left origin anchored at the primary display,
        // which is `screens.first`. Flip around its top edge to reach CG space.
        guard let primary = screens.first else { return [] }
        let primaryTop = primary.frame.maxY
        return screens.map { screen in
            ScreenInfo(frame: flip(screen.frame, primaryTop: primaryTop),
                       visibleFrame: flip(screen.visibleFrame, primaryTop: primaryTop))
        }
    }

    /// Converts an AppKit rect (bottom-left origin, anchored at the primary
    /// display) into CG global coordinates (top-left origin). Exposed for tests.
    static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
