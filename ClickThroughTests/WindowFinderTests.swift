import XCTest
import CoreGraphics
@testable import ClickThrough

/// The click policy is a pure function, so the interesting behaviour - including
/// the multi-monitor and system-UI cases that are awkward to reproduce by hand -
/// is covered here without needing a window server.
final class WindowFinderTests: XCTestCase {

    // A 1512x982 primary display with a 33pt menu bar and a 70pt Dock, plus a
    // secondary 1920x1080 display placed above and to the left of it. Negative
    // coordinates are exactly what a real "monitor above the laptop" setup gives.
    private let primary = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 879))
    private let secondary = ScreenInfo(frame: CGRect(x: -200, y: -1080, width: 1920, height: 1080),
                                       visibleFrame: CGRect(x: -200, y: -1047, width: 1920, height: 1047))
    private var screens: [ScreenInfo] { [primary, secondary] }

    private let ownPID: pid_t = 99
    private let frontPID: pid_t = 10
    private let otherPID: pid_t = 20

    private func window(pid: pid_t, id: CGWindowID, rect: CGRect,
                        layer: Int = 0, alpha: Double = 1, owner: String = "App") -> WindowSnapshot {
        WindowSnapshot(id: id, pid: pid, layer: layer, bounds: rect, alpha: alpha, ownerName: owner)
    }

    /// Window covering the whole primary display's visible area.
    private func fullWindow(pid: pid_t, id: CGWindowID, layer: Int = 0,
                            alpha: Double = 1, owner: String = "App") -> WindowSnapshot {
        window(pid: pid, id: id, rect: CGRect(x: 0, y: 33, width: 1512, height: 879),
               layer: layer, alpha: alpha, owner: owner)
    }

    /// The menu bar the window server draws on the primary display: a strip across
    /// the full width of the display's top edge. Level 24 is what macOS uses, but
    /// the policy recognises it by shape, not by level. Present in most fixtures
    /// because it is present on a real system.
    /// most fixtures because it is present on a real system.
    private var primaryMenuBar: WindowSnapshot {
        window(pid: 2, id: 900, rect: CGRect(x: 0, y: 0, width: 1512, height: 33),
               layer: 24, owner: WindowFinder.windowServerOwnerName)
    }

    /// The menu bar on the secondary display.
    private var secondaryMenuBar: WindowSnapshot {
        window(pid: 2, id: 901, rect: CGRect(x: -200, y: -1080, width: 1920, height: 33),
               layer: 24, owner: WindowFinder.windowServerOwnerName)
    }

    /// The Dock's full-display backdrop window, which is in the window list
    /// whenever the Dock is on screen at all.
    private var dockBackdrop: WindowSnapshot {
        window(pid: 3, id: 902, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
               layer: 20, owner: WindowFinder.dockOwnerName)
    }

    /// A window extending to the bottom edge of the primary display, so it lies
    /// under the Dock the way a maximised window really does.
    private var windowUnderTheDock: WindowSnapshot {
        window(pid: otherPID, id: 2, rect: CGRect(x: 0, y: 33, width: 1512, height: 949))
    }

    /// The strip a bottom Dock occupies on the primary display.
    private let dockStrip = CGRect(x: 56, y: 886, width: 1400, height: 86)

    private func act(_ point: CGPoint, _ windows: [WindowSnapshot],
                     frontmostPID: pid_t? = nil, frontmostIsSystemUI: Bool = false,
                     modifiers: CGEventFlags = [], dockStrip: CGRect = .null,
                     dockShowsStack: Bool = false) -> ClickAction {
        WindowFinder.action(for: point,
                            windows: { windows },
                            frontmostPID: frontmostPID ?? frontPID,
                            frontmostIsSystemUI: frontmostIsSystemUI,
                            screens: screens,
                            ownPID: ownPID,
                            modifiers: modifiers,
                            dockState: { _ in DockState(strip: dockStrip, showsStack: dockShowsStack) })
    }

    // MARK: - Core behaviour

    func testClickOnActiveWindowIsLeftAlone() {
        let windows = [fullWindow(pid: frontPID, id: 1)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows), .ignore(.alreadyFrontWindow))
    }

    func testClickOnInactiveApplicationActivatesIt() {
        let inactive = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        let windows = [inactive, fullWindow(pid: frontPID, id: 1)]
        XCTAssertEqual(act(CGPoint(x: 200, y: 200), windows),
                       .activate(pid: otherPID, windowID: 2, windowBounds: inactive.bounds, raiseWindow: false))
    }

    /// Clicking the *frontmost* application's other window must focus that
    /// window, not leave the click to be eaten by the window becoming key.
    func testClickOnBackgroundWindowOfActiveApplicationRaisesThatWindow() {
        // The front window must not cover the background one, otherwise the
        // click would simply land on the front window.
        let front = window(pid: frontPID, id: 1, rect: CGRect(x: 0, y: 33, width: 600, height: 400))
        let back = window(pid: frontPID, id: 2, rect: CGRect(x: 900, y: 600, width: 400, height: 300))
        let windows = [front, back]
        XCTAssertEqual(act(CGPoint(x: 1000, y: 700), windows),
                       .activate(pid: frontPID, windowID: 2, windowBounds: back.bounds, raiseWindow: true))
    }

    /// When an inactive app has several windows, the clicked one - not whichever
    /// happens to be that app's front window - must come forward.
    func testClickOnBackgroundWindowOfInactiveApplicationRaisesTheClickedWindow() {
        let appFront = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 300, height: 200))
        let appBack = window(pid: otherPID, id: 3, rect: CGRect(x: 600, y: 400, width: 300, height: 200))
        let windows = [appFront, appBack, fullWindow(pid: frontPID, id: 1)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows),
                       .activate(pid: otherPID, windowID: 3, windowBounds: appBack.bounds, raiseWindow: true))
    }

    // MARK: - Multiple displays

    func testWindowOnSecondaryDisplayWithNegativeCoordinates() {
        let onSecondary = window(pid: otherPID, id: 2, rect: CGRect(x: -100, y: -900, width: 800, height: 600))
        let windows = [onSecondary, fullWindow(pid: frontPID, id: 1)]
        XCTAssertEqual(act(CGPoint(x: 100, y: -600), windows),
                       .activate(pid: otherPID, windowID: 2, windowBounds: onSecondary.bounds, raiseWindow: false))
    }

    func testPointOnNoDisplayFindsNoWindow() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 5000, y: 5000), windows), .ignore(.noWindowUnderCursor))
    }

    func testMenuBarStripIsIgnored() {
        let windows = [primaryMenuBar, dockBackdrop, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 10), windows), .ignore(.menuBarOrDock))
    }

    func testMenuBarOnSecondaryDisplayIsIgnored() {
        let onSecondary = window(pid: otherPID, id: 2,
                                 rect: CGRect(x: -200, y: -1080, width: 1920, height: 400))
        let windows = [secondaryMenuBar, onSecondary]
        XCTAssertEqual(act(CGPoint(x: 700, y: -1070), windows), .ignore(.menuBarOrDock))
    }

    /// The Dock reports the strip it actually occupies; that is what decides a
    /// Dock click, not the inset the display reserves.
    func testDockStripIsIgnored() {
        let windows = [primaryMenuBar, dockBackdrop, windowUnderTheDock]
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows, dockStrip: dockStrip),
                       .ignore(.menuBarOrDock))
    }

    /// An automatically hidden Dock leaves the display's visible frame at full
    /// height, so the reserved-inset test cannot see it - but the Dock still
    /// reports the strip it occupies once revealed, and a click there must not
    /// reach the window behind it.
    func testRevealedAutoHiddenDockIsIgnoredEvenWithNoReservedInset() {
        let noInset = ScreenInfo(frame: primary.frame, visibleFrame: primary.frame)
        let windows = [primaryMenuBar, dockBackdrop, windowUnderTheDock]
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 950),
                                        windows: { windows },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: [noInset, secondary],
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in DockState(strip: self.dockStrip, showsStack: false) })
        XCTAssertEqual(action, .ignore(.menuBarOrDock))
    }

    /// A hidden Dock reports a strip below the bottom of the display, so the same
    /// click belongs to the window.
    func testHiddenDockDoesNotSwallowClicks() {
        let offScreenStrip = CGRect(x: 56, y: 982, width: 1400, height: 86)
        let app = windowUnderTheDock
        let windows = [primaryMenuBar, dockBackdrop, app]
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows, dockStrip: offScreenStrip),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// If Accessibility does not answer, the reserved inset is still a reasonable
    /// answer for the ordinary always-visible Dock.
    func testDockStripFallsBackToTheReservedInsetWhenTheDockIsSilent() {
        let windows = [primaryMenuBar, dockBackdrop, windowUnderTheDock]
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 950),
                                        windows: { windows },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in nil })
        XCTAssertEqual(action, .ignore(.menuBarOrDock))
    }

    /// A full-screen window covers the Dock, and macOS takes the Dock's window
    /// out of the on-screen list for that display. The bottom strip is then part
    /// of the window - where a video player keeps its controls - so the click
    /// must be delivered rather than written off as a Dock click.
    func testDockStripBelongsToAFullScreenWindowWhenTheDockIsNotOnScreen() {
        let fullScreen = window(pid: otherPID, id: 2,
                                rect: CGRect(x: 0, y: 33, width: 1512, height: 949))
        let windows = [primaryMenuBar, fullScreen]
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows),
                       .activate(pid: otherPID, windowID: 2, windowBounds: fullScreen.bounds,
                                 raiseWindow: false))
    }

    /// Same again for the menu bar strip macOS reserves on every display: a
    /// full-screen window on the secondary display covers it, and the window
    /// server stops drawing a menu bar there.
    func testReservedMenuBarStripBelongsToAFullScreenWindowOnASecondaryDisplay() {
        let fullScreen = window(pid: otherPID, id: 2,
                                rect: CGRect(x: -200, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(act(CGPoint(x: 700, y: -1070), [fullScreen]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: fullScreen.bounds,
                                 raiseWindow: false))
    }

    // MARK: - System and special UI

    func testMissionControlAndOtherSystemUIAreIgnored() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, frontmostIsSystemUI: true),
                       .ignore(.systemUIFrontmost))
    }

    /// Mission Control does not become the frontmost application, so it has to be
    /// recognised from its own windows: a backdrop over the display plus the
    /// Spaces bar across the top of it.
    func testMissionControlIsRecognisedFromItsWindowsNotTheFrontmostApp() {
        let backdrop = window(pid: 5, id: 910, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              layer: 19, owner: WindowFinder.windowManagerOwnerName)
        let spacesBar = window(pid: 5, id: 911, rect: CGRect(x: 0, y: 0, width: 1512, height: 128),
                               layer: 14, owner: WindowFinder.windowManagerOwnerName)
        let windows = [backdrop, spacesBar, dockBackdrop, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows), .ignore(.systemUIOnScreen))
    }

    /// Clicking the wallpaper leaves `WindowManager` holding a full-display window
    /// that looks almost exactly like Mission Control's backdrop, and it stays
    /// there. Taking it for system UI would make the utility ignore every click.
    func testWallpaperFocusBackdropAloneDoesNotSuppressActivation() {
        let backdrop = window(pid: 5, id: 910, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              layer: 18, owner: WindowFinder.windowManagerOwnerName)
        let app = fullWindow(pid: otherPID, id: 2)
        let windows = [backdrop, dockBackdrop, app]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// Stage Manager's strip is also owned by `WindowManager` but covers no
    /// display, so it must not suppress anything.
    func testWindowManagerStripDoesNotSuppressActivation() {
        let strip = window(pid: 5, id: 911, rect: CGRect(x: 0, y: 100, width: 120, height: 600),
                           layer: 19, owner: WindowFinder.windowManagerOwnerName)
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [strip, dockBackdrop, app]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    func testOpenMenuAnywhereSuppressesActivation() {
        let menu = window(pid: frontPID, id: 9, rect: CGRect(x: 40, y: 40, width: 200, height: 300),
                          layer: WindowFinder.popUpMenuLayer)
        let windows = [menu, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows), .ignore(.menuOpen))
    }

    func testFloatingPanelAboveTheWindowSuppressesActivation() {
        let panel = window(pid: frontPID, id: 8, rect: CGRect(x: 600, y: 400, width: 300, height: 200), layer: 3)
        let windows = [panel, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows), .ignore(.overlayWindow))
    }

    /// The Dock and Notification Centre each keep a window covering the whole
    /// display above ordinary windows, and the window server owns the pointer
    /// overlay, which is under the cursor by definition. None may hide the
    /// application window beneath.
    func testSystemBackdropsAndCursorOverlayAreTransparentToTargeting() {
        let dock = window(pid: 1, id: 30, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                          layer: 20, owner: "Dock")
        let notificationCentre = window(pid: 4, id: 32, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        layer: 21, owner: "Notification Center")
        let cursor = window(pid: 2, id: 31, rect: CGRect(x: 695, y: 495, width: 28, height: 40),
                            layer: 2147483630, owner: "Window Server")
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [cursor, notificationCentre, dock, app]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// A small overlay from the same processes is still respected: it is real UI.
    func testSmallSystemOverlayStillSuppressesActivation() {
        let banner = window(pid: 4, id: 33, rect: CGRect(x: 1100, y: 40, width: 360, height: 100),
                            layer: 21, owner: "Notification Center")
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 1200, y: 80), [banner, app]), .ignore(.overlayWindow))
    }
    func testFullyTransparentWindowDoesNotBlockTargeting() {
        let ghost = fullWindow(pid: 55, id: 40, alpha: 0)
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [ghost, app]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    func testDesktopAndWallpaperWindowsAreNotTargets() {
        let desktop = window(pid: 3, id: 50, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                             layer: -2147483603, owner: "Finder")
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [desktop]), .ignore(.noWindowUnderCursor))
    }

    func testOwnWindowsAreNeverActivated() {
        let mine = fullWindow(pid: ownPID, id: 60)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [mine]), .ignore(.ownApplication))
    }

    /// A Dock stack - the fan from a folder in the Dock - is drawn inside the
    /// Dock's own full-display window, and the Dock is not frontmost while one is
    /// open. Clicking a file in the stack must not activate the window behind it.
    func testClickIsLeftAloneWhileADockStackIsOpen() {
        let windows = [primaryMenuBar, dockBackdrop, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, dockShowsStack: true),
                       .ignore(.dockStackOpen))
    }

    func testClickActivatesNormallyWhenNoDockStackIsOpen() {
        let app = fullWindow(pid: otherPID, id: 2)
        let windows = [primaryMenuBar, dockBackdrop, app]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, dockShowsStack: false),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// The Dock only covers its own display, so an open stack there cannot be a
    /// reason to suppress a click on a different display.
    func testDockStackDoesNotSuppressClicksOnAnotherDisplay() {
        let onSecondary = window(pid: otherPID, id: 2,
                                 rect: CGRect(x: -100, y: -900, width: 800, height: 600))
        let windows = [primaryMenuBar, dockBackdrop, onSecondary]
        XCTAssertEqual(act(CGPoint(x: 100, y: -600), windows, dockShowsStack: true),
                       .activate(pid: otherPID, windowID: 2, windowBounds: onSecondary.bounds,
                                 raiseWindow: false))
    }

    // MARK: - Modifiers

    func testCommandClickIsLeftToMacOS() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, modifiers: .maskCommand), .ignore(.modifierHeld))
    }

    func testControlClickIsLeftToMacOS() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, modifiers: .maskControl), .ignore(.modifierHeld))
    }

    func testShiftClickStillActivates() {
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [app], modifiers: .maskShift),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }


    // MARK: - Cost

    /// Reading the on-screen window list is a round trip to the window server and
    /// is essentially the whole cost of handling a click, so the two rules that
    /// can decide without it must not trigger the read.
    func testModifierClickDoesNotReadTheWindowList() {
        var reads = 0
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 500),
                                        windows: { reads += 1; return [self.fullWindow(pid: self.otherPID, id: 2)] },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: .maskCommand)
        XCTAssertEqual(action, .ignore(.modifierHeld))
        XCTAssertEqual(reads, 0)
    }

    func testSystemUIFrontmostDoesNotReadTheWindowList() {
        var reads = 0
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 500),
                                        windows: { reads += 1; return [self.fullWindow(pid: self.otherPID, id: 2)] },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: true,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [])
        XCTAssertEqual(action, .ignore(.systemUIFrontmost))
        XCTAssertEqual(reads, 0)
    }

    /// And when it is needed, it is read exactly once however many rules consult it.
    func testTheWindowListIsReadOnlyOncePerClick() {
        var reads = 0
        let app = fullWindow(pid: otherPID, id: 2)
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 500),
                                        windows: { reads += 1; return [self.primaryMenuBar, self.dockBackdrop, app] },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in DockState(strip: self.dockStrip, showsStack: false) })
        XCTAssertEqual(action, .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
        XCTAssertEqual(reads, 1)
    }

    // MARK: - Coordinate conversion

    func testAppKitToCoreGraphicsFlipForStackedDisplays() {
        // Primary is 982pt tall; a secondary display sitting above it has a
        // positive AppKit origin and a negative CG origin.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(ScreenGeometry.flip(above, primaryTop: 982),
                       CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let primaryRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(ScreenGeometry.flip(primaryRect, primaryTop: 982), primaryRect)
    }
}
