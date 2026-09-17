import AppKit

/// One on-screen window, as reported by the window server.
///
/// Deliberately does *not* carry the window title: `kCGWindowName` requires the
/// Screen Recording permission, and this utility asks only for Accessibility.
struct WindowSnapshot: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// Window level. 0 is an ordinary application window; menus, panels and
    /// system overlays sit above, desktop and wallpaper below.
    let layer: Int
    let bounds: CGRect
    let alpha: Double
    let ownerName: String
}

/// What the event tap should do with a click.
enum ClickAction: Equatable {
    /// Leave the event completely alone - macOS behaves exactly as it normally would.
    case ignore(IgnoreReason)
    /// Activate `pid` (and optionally raise the specific window) before letting
    /// the original event through.
    case activate(pid: pid_t, windowID: CGWindowID, windowBounds: CGRect, raiseWindow: Bool)
}

enum IgnoreReason: String, Equatable {
    case modifierHeld
    case systemUIFrontmost
    case menuOpen
    case offScreen
    case menuBarOrDock
    case noWindowUnderCursor
    case overlayWindow
    case ownApplication
    case alreadyFrontWindow
}

enum WindowFinder {
    /// Window levels above ordinary windows that mean "a menu is being tracked".
    /// Measured on macOS: an open NSMenu (menu bar menu, context menu, pop-up
    /// button menu) shows up as a window at level 101 owned by its application.
    static let popUpMenuLayer = 101

    /// Processes whose windows are never activation targets.
    ///
    /// `Window Server` owns the hardware pointer overlay, which sits at a very
    /// high level *directly under the pointer at all times*, plus the menu bar
    /// backdrop. `WindowManager` owns the wallpaper and Stage Manager surfaces.
    static let nonTargetOwners: Set<String> = ["Window Server", "WindowManager"]

    /// Applications that, when frontmost, mean the system is showing its own UI
    /// (Mission Control, Launchpad, a Dock menu, the login window, a screen saver).
    /// Clicking through to an app underneath that UI is never what the user means.
    static let systemUIBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.WindowManager",
    ]

    /// Reads the current on-screen window list, front to back.
    ///
    /// `.excludeDesktopElements` drops the desktop icon and wallpaper windows.
    /// Cost is ~2 ms once warm (see `warmUp()`), which is acceptable on mouse-down
    /// but would not be on mouse-moved - hence this is only ever called for clicks.
    static func onScreenWindows() -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return WindowSnapshot(id: id,
                                  pid: pid,
                                  layer: layer,
                                  bounds: bounds,
                                  alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1,
                                  ownerName: (info[kCGWindowOwnerName as String] as? String) ?? "")
        }
    }

    /// The first call into the window-server client library costs ~50 ms while the
    /// connection is set up. Pay that at launch instead of on the user's first click.
    static func warmUp() {
        _ = onScreenWindows()
    }

    /// Decides what to do about a click. Pure function: everything it needs is a
    /// parameter, so the whole policy is unit-testable without a window server.
    ///
    /// - Parameters:
    ///   - point: click location in CG global coordinates.
    ///   - windows: on-screen windows, front to back.
    ///   - frontmostPID: process that currently owns the menu bar.
    ///   - frontmostIsSystemUI: true when the frontmost app is system UI.
    ///   - screens: current display layout.
    ///   - ownPID: this process, which must never activate itself.
    ///   - modifiers: modifier keys held at mouse-down.
    static func action(for point: CGPoint,
                       windows: [WindowSnapshot],
                       frontmostPID: pid_t,
                       frontmostIsSystemUI: Bool,
                       screens: [ScreenInfo],
                       ownPID: pid_t,
                       modifiers: CGEventFlags) -> ClickAction {
        // Command-click and control-click already have their own meanings on an
        // inactive window (move it without activating; open a context menu), so
        // they are passed through untouched.
        if modifiers.contains(.maskCommand) || modifiers.contains(.maskControl) {
            return .ignore(.modifierHeld)
        }

        // Mission Control, Launchpad, Dock menus, login window, screen saver.
        if frontmostIsSystemUI { return .ignore(.systemUIFrontmost) }

        // While a menu is being tracked anywhere on screen, a click is a dismissal
        // gesture. Activating whatever sits under the pointer would raise a window
        // the user never meant to touch.
        if windows.contains(where: { $0.layer == popUpMenuLayer }) { return .ignore(.menuOpen) }

        guard let screen = screens.first(where: { $0.frame.contains(point) }) else {
            return .ignore(.offScreen)
        }
        // Outside the visible frame means the menu bar or the Dock: leave both alone.
        guard screen.visibleFrame.contains(point) else { return .ignore(.menuBarOrDock) }

        guard let target = topmostTargetableWindow(at: point, in: windows,
                                                  displays: screens.map(\.frame)) else {
            return .ignore(.noWindowUnderCursor)
        }
        // Anything above the ordinary window level is a panel, popover, tooltip,
        // HUD or system overlay. Never activate what happens to be behind it.
        guard target.layer == 0 else { return .ignore(.overlayWindow) }
        guard target.pid != ownPID else { return .ignore(.ownApplication) }

        let isFrontApplication = target.pid == frontmostPID
        let appFrontWindow = frontWindow(ofPID: target.pid, in: windows)

        if isFrontApplication && appFrontWindow?.id == target.id {
            // Already the active window: macOS delivers this click normally.
            return .ignore(.alreadyFrontWindow)
        }

        // Raising is only needed when the click landed on a window that is not
        // already its application's front window; otherwise activating the app is
        // enough and we avoid a round trip to a possibly busy process.
        let needsRaise = appFrontWindow?.id != target.id
        return .activate(pid: target.pid,
                         windowID: target.id,
                         windowBounds: target.bounds,
                         raiseWindow: needsRaise)
    }

    /// Front-most window at `point` that could plausibly be clicked by the user.
    ///
    /// - Parameter displays: display frames, used to recognise backdrop windows.
    static func topmostTargetableWindow(at point: CGPoint,
                                        in windows: [WindowSnapshot],
                                        displays: [CGRect]) -> WindowSnapshot? {
        windows.first { window in
            window.alpha > 0                              // fully transparent overlays pass clicks through
                && window.layer >= 0                      // desktop, wallpaper and backstop windows
                && !nonTargetOwners.contains(window.ownerName)
                && !isBackdrop(window, displays: displays)
                && window.bounds.contains(point)
        }
    }

    /// A window above the ordinary level that covers an entire display is a
    /// backdrop, not something the user clicked: the Dock and Notification
    /// Centre both keep one permanently on screen, and screen-tinting utilities
    /// add more. Treating one as the topmost window would make this utility
    /// ignore every click for as long as it exists.
    private static func isBackdrop(_ window: WindowSnapshot, displays: [CGRect]) -> Bool {
        window.layer > 0 && displays.contains { window.bounds.contains($0) }
    }

    /// The given application's front-most ordinary window, in global z-order.
    private static func frontWindow(ofPID pid: pid_t, in windows: [WindowSnapshot]) -> WindowSnapshot? {
        windows.first { $0.pid == pid && $0.layer == 0 && $0.alpha > 0 }
    }
}
