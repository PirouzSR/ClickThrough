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

    private func act(_ point: CGPoint, _ windows: [WindowSnapshot],
                     frontmostPID: pid_t? = nil, frontmostIsSystemUI: Bool = false,
                     modifiers: CGEventFlags = []) -> ClickAction {
        WindowFinder.action(for: point,
                            windows: windows,
                            frontmostPID: frontmostPID ?? frontPID,
                            frontmostIsSystemUI: frontmostIsSystemUI,
                            screens: screens,
                            ownPID: ownPID,
                            modifiers: modifiers)
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

    func testPointOnNoDisplayIsIgnored() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 5000, y: 5000), windows), .ignore(.offScreen))
    }

    func testMenuBarStripIsIgnored() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 10), windows), .ignore(.menuBarOrDock))
    }

    func testDockStripIsIgnored() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows), .ignore(.menuBarOrDock))
    }

    // MARK: - System and special UI

    func testMissionControlAndOtherSystemUIAreIgnored() {
        let windows = [fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), windows, frontmostIsSystemUI: true),
                       .ignore(.systemUIFrontmost))
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
