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
    case sameDisplay
    case focusDisplayUnknown
    case systemUIFrontmost
    case systemUIOnScreen
    case menuOpen
    case menuBarOrDock
    case noWindowUnderCursor
    case notificationContent
    case overlayWindow
    case ownApplication
    case alreadyFrontWindow
    case dockStackOpen
}

enum WindowFinder {
    /// Window levels above ordinary windows that mean "a menu is being tracked".
    /// Measured on macOS: an open NSMenu (menu bar menu, context menu, pop-up
    /// button menu) shows up as a window at level 101 owned by its application.
    static let popUpMenuLayer = 101

    /// Processes whose windows are never activation targets.
    ///
    /// `Window Server` owns the hardware pointer overlay, which sits at a very
    /// high level *directly under the pointer at all times*, plus the menu bar.
    /// `WindowManager` owns the wallpaper, Stage Manager, and Mission Control.
    static let windowServerOwnerName = "Window Server"
    static let windowManagerOwnerName = "WindowManager"
    static let nonTargetOwners: Set<String> = [windowServerOwnerName, windowManagerOwnerName]

    /// `kCGWindowOwnerName` for the Dock and for Notification Center. These are
    /// process names, not localised display names, so they are stable across
    /// languages.
    static let dockOwnerName = "Dock"
    static let notificationCenterOwnerName = "Notification Center"

    /// Applications that, when frontmost, mean the system is showing its own UI
    /// (a Dock menu, the login window, a screen saver). Clicking through to an
    /// app underneath that UI is never what the user means.
    ///
    /// Mission Control is deliberately *not* covered by this: it does not become
    /// frontmost, and is recognised from the window list instead.
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
    ///   - windows: on-screen windows, front to back. A closure, not an array,
    ///     because reading the list costs a round trip to the window server -
    ///     measured at about a millisecond, which is essentially the whole cost
    ///     of handling a click - and the first two rules below do not need it.
    ///   - frontmostPID: process that currently owns the menu bar.
    ///   - frontmostIsSystemUI: true when the frontmost app is system UI.
    ///   - screens: current display layout.
    ///   - ownPID: this process, which must never activate itself.
    ///   - modifiers: modifier keys held at mouse-down.
    ///   - dockState: asks the Dock what it is showing. Injected so that the
    ///     whole policy stays a pure function, and only consulted for a click
    ///     that would otherwise activate something.
    ///   - notificationRects: asks Notification Center where it is drawing,
    ///     under the same terms.
    static func action(for point: CGPoint,
                       windows: () -> [WindowSnapshot],
                       frontmostPID: pid_t,
                       frontmostIsSystemUI: Bool,
                       screens: [ScreenInfo],
                       ownPID: pid_t,
                       modifiers: CGEventFlags,
                       dockState: (pid_t) -> DockState? = { _ in nil },
                       notificationRects: (pid_t, CGRect) -> [CGRect] = { _, _ in [] }) -> ClickAction {
        // Command-click and control-click already have their own meanings on an
        // inactive window (move it without activating; open a context menu), so
        // they are passed through untouched.
        if modifiers.contains(.maskCommand) || modifiers.contains(.maskControl) {
            return .ignore(.modifierHeld)
        }

        // A Dock menu, the login window or a screen saver: the system has taken
        // over, and clicking through to an application is never what is meant.
        if frontmostIsSystemUI { return .ignore(.systemUIFrontmost) }

        // Everything from here needs to know what is on screen. Reading that is
        // ~1 ms, so it is deliberately not read for the two rules above.
        let windows = windows()
        let displays = screens.map(\.frame)

        // The click this utility exists for is the one that crosses displays:
        // the window you clicked is on a different screen from the one that has
        // focus, so macOS spends your click on moving focus there instead of on
        // the thing you clicked.
        //
        // macOS discards that first click within a single display too, and this
        // deliberately no longer does anything about it. Every intervention is a
        // chance to get a click wrong, and the repeated way to get one wrong is a
        // system surface painted into a window that covers a whole display - a
        // notification and its close button, a Dock stack, something this code
        // has never seen - which the targeting below looks straight past, so the
        // click lands on the window behind it instead. That list is not fixed:
        // it is whatever this version of macOS happens to do. Standing aside for
        // clicks that stay on the focused display removes most of that risk
        // without having to keep the list complete, at the price of leaving the
        // smaller annoyance - the window you wanted is on the screen you are
        // already looking at - to macOS. It also means a single-display setup
        // never sees this utility do anything at all.
        guard let clickedDisplay = display(containing: point, in: displays) else {
            // Between or beyond the displays: there is no window there either.
            return .ignore(.noWindowUnderCursor)
        }
        guard let focusedDisplay = focusDisplay(frontmostPID: frontmostPID,
                                                windows: windows, displays: displays) else {
            return .ignore(.focusDisplayUnknown)
        }
        guard clickedDisplay != focusedDisplay else { return .ignore(.sameDisplay) }

        // Mission Control. It is owned by `WindowManager`, and - measured on
        // macOS 27 - it does *not* become the frontmost application, so the check
        // above cannot see it; and it covers each display with a window above the
        // ordinary level, which the backdrop rule further down would look
        // straight past before activating whichever window lay under the pointer.
        //
        // It is recognised by two surfaces together, not one: a backdrop covering
        // a display *and* the Spaces bar, a short strip across the full width of
        // a display's top edge. The backdrop alone is not enough, because
        // clicking the wallpaper leaves `WindowManager` holding an almost
        // identical full-display window - and treating that as system UI would
        // make the utility ignore every click until the user clicked a window
        // again. Missing an unusual Mission Control simply leaves the old
        // behaviour; a false positive here looks like the utility is dead, so the
        // test deliberately errs towards missing one.
        if isMissionControlOnScreen(windows, displays: displays) {
            return .ignore(.systemUIOnScreen)
        }

        // While a menu is being tracked anywhere on screen, a click is a dismissal
        // gesture. Activating whatever sits under the pointer would raise a window
        // the user never meant to touch.
        if windows.contains(where: { $0.layer == popUpMenuLayer }) { return .ignore(.menuOpen) }

        // The menu bar, wherever it is currently being drawn. This comes from the
        // window list rather than from `NSScreen.visibleFrame` because macOS
        // reserves the menu bar strip on *every* display permanently, while the
        // window server only keeps a menu bar window where one is really on
        // screen. The difference matters for a full-screen window, which covers
        // the strip and makes the window go away: without this, clicks on the top
        // edge of a full-screen video on a second display were being discarded.
        if menuBar(at: point, in: windows, displays: displays) != nil { return .ignore(.menuBarOrDock) }

        guard let target = topmostTargetableWindow(at: point, in: windows,
                                                  displays: displays) else {
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

        // Everything the Dock draws - its strip of icons and any open stack -
        // goes into one window covering the whole display, which the backdrop
        // rule above deliberately looks past, and the Dock is not frontmost for
        // either. Asking the Dock is the only way to tell a click on it from a
        // click on the window behind it. See `DockInspector`.
        if let dock = backdrop(ownedBy: dockOwnerName, at: point, in: windows, displays: displays) {
            if let state = dockState(dock.pid) {
                if state.strip.contains(point) { return .ignore(.menuBarOrDock) }
                if state.showsStack { return .ignore(.dockStackOpen) }
            } else if let screen = screens.first(where: { $0.frame.contains(point) }),
                      !screen.visibleFrame.contains(point) {
                // The Dock did not answer. Fall back to the strip the display
                // reserves, which is right for the ordinary always-visible Dock.
                return .ignore(.menuBarOrDock)
            }
        }

        // Notification Center draws a banner - and the whole notification panel
        // - into a window covering its display, in exactly the way the Dock
        // does, so the same question has to be asked of it: is this click on a
        // notification, or on the window behind one? Clicking a notification's
        // close button and having the window underneath come forward instead was
        // the reported symptom. See `NotificationCenterInspector`.
        if let centre = backdrop(ownedBy: notificationCenterOwnerName, at: point,
                                 in: windows, displays: displays),
           notificationRects(centre.pid, centre.bounds).contains(where: { $0.contains(point) }) {
            return .ignore(.notificationContent)
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
    /// Centre each keep one on screen almost all of the time, and screen-tinting
    /// utilities add more. Treating one as the topmost window would make this
    /// utility ignore every click for as long as it exists.
    ///
    /// Looking past them is why the Dock has to be asked about its own clicks
    /// separately, and why Mission Control is checked for by name above.
    private static func isBackdrop(_ window: WindowSnapshot, displays: [CGRect]) -> Bool {
        window.layer > 0 && displays.contains { window.bounds.contains($0) }
    }

    /// True while Mission Control is on screen.
    ///
    /// See the call site for why both surfaces are required.
    private static func isMissionControlOnScreen(_ windows: [WindowSnapshot],
                                                 displays: [CGRect]) -> Bool {
        var hasBackdrop = false
        var hasSpacesBar = false
        for window in windows where window.ownerName == windowManagerOwnerName {
            if isBackdrop(window, displays: displays) {
                hasBackdrop = true
            } else if window.layer > 0, displays.contains(where: {
                $0.minY == window.bounds.minY && $0.width == window.bounds.width
                    && window.bounds.height < $0.height
            }) {
                hasSpacesBar = true
            }
            if hasBackdrop && hasSpacesBar { return true }
        }
        return false
    }

    /// The menu bar window covering `point`, if the window server is drawing one
    /// there right now.
    ///
    /// Identified by shape rather than by window level: the only window the window
    /// server puts across the full width of a display's top edge is the menu bar.
    /// That avoids depending on the level's numeric value, and the level is not
    /// what makes it a menu bar anyway.
    private static func menuBar(at point: CGPoint, in windows: [WindowSnapshot],
                                displays: [CGRect]) -> WindowSnapshot? {
        windows.first { window in
            window.ownerName == windowServerOwnerName
                && window.layer > 0
                && window.bounds.contains(point)
                && displays.contains { $0.minY == window.bounds.minY && $0.width == window.bounds.width }
        }
    }

    /// A named process's full-display window, when it is on screen and covers
    /// `point`. Used for the Dock and for Notification Center, the two system
    /// surfaces that have to be asked about their own clicks.
    ///
    /// Its process identifier is what the inspectors need, and taking it from
    /// the window list means neither process has to be looked up by bundle
    /// identifier on the event-tap thread.
    private static func backdrop(ownedBy owner: String, at point: CGPoint,
                                 in windows: [WindowSnapshot],
                                 displays: [CGRect]) -> WindowSnapshot? {
        windows.first {
            $0.ownerName == owner && isBackdrop($0, displays: displays) && $0.bounds.contains(point)
        }
    }

    /// The display containing `point`, if any.
    private static func display(containing point: CGPoint, in displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(point) }
    }

    /// The display that currently holds focus.
    ///
    /// That is wherever the frontmost application's front window is. When the
    /// frontmost application has no window on screen - Finder, after a click on
    /// the desktop, is the everyday case - the top-most window of any
    /// application is the best answer available, and still says which display
    /// the user was working on. With nothing on screen at all there is no answer,
    /// and the click is left alone.
    private static func focusDisplay(frontmostPID: pid_t, windows: [WindowSnapshot],
                                     displays: [CGRect]) -> CGRect? {
        guard let focused = frontWindow(ofPID: frontmostPID, in: windows)
                ?? windows.first(where: { $0.layer == 0 && $0.alpha > 0 })
        else { return nil }
        return display(mostlyCovering: focused.bounds, in: displays)
    }

    /// The display a window is on, which for a window straddling two displays is
    /// the one showing more of it - the same rule macOS itself uses.
    private static func display(mostlyCovering bounds: CGRect, in displays: [CGRect]) -> CGRect? {
        let best = displays.max { overlap($0, bounds) < overlap($1, bounds) }
        guard let best, overlap(best, bounds) > 0 else { return nil }
        return best
    }

    private static func overlap(_ display: CGRect, _ bounds: CGRect) -> CGFloat {
        let intersection = display.intersection(bounds)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// The given application's front-most ordinary window, in global z-order.
    private static func frontWindow(ofPID pid: pid_t, in windows: [WindowSnapshot]) -> WindowSnapshot? {
        windows.first { $0.pid == pid && $0.layer == 0 && $0.alpha > 0 }
    }
}
