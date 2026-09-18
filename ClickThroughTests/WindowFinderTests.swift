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

    /// Where focus is, for a fixture whose click is on the primary display: a
    /// window of the frontmost application, on the secondary one.
    ///
    /// Almost every fixture needs one, because the policy only ever acts on a
    /// click that lands on a different display from the one holding focus -
    /// without it, a click on the primary display would not cross displays and
    /// the right answer would be "do nothing". It is put at the front of the
    /// window list so that it is unambiguously that application's front window,
    /// and kept small and out of the way so that it is never what is clicked.
    private var focusOnSecondary: WindowSnapshot {
        window(pid: frontPID, id: 100, rect: CGRect(x: -200, y: -200, width: 200, height: 200))
    }

    /// The same, the other way round, for a fixture whose click is on the
    /// secondary display.
    private var focusOnPrimary: WindowSnapshot {
        window(pid: frontPID, id: 101, rect: CGRect(x: 0, y: 782, width: 200, height: 200))
    }

    /// The menu bar the window server draws on the primary display: a strip across
    /// the full width of the display's top edge. Level 24 is what macOS uses, but
    /// the policy recognises it by shape, not by level. Present in most fixtures
    /// because it is present on a real system.
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

    /// Notification Center's backdrop: one window over the whole display, which
    /// is what it draws a banner - or the notification panel - inside.
    private var notificationBackdrop: WindowSnapshot {
        window(pid: 4, id: 903, rect: CGRect(x: 0, y: 0, width: 1512, height: 982),
               layer: 21, owner: WindowFinder.notificationCenterOwnerName)
    }

    /// Where a banner really sits, measured on macOS: 344x58 below the menu bar
    /// at the right-hand edge of the display.
    private let notificationBanner = CGRect(x: 1152, y: 49, width: 344, height: 58)

    /// A window extending to the bottom edge of the primary display, so it lies
    /// under the Dock the way a maximised window really does.
    private var windowUnderTheDock: WindowSnapshot {
        window(pid: otherPID, id: 2, rect: CGRect(x: 0, y: 33, width: 1512, height: 949))
    }

    /// The strip a bottom Dock occupies on the primary display.
    private let dockStrip = CGRect(x: 56, y: 886, width: 1400, height: 86)

    /// - Parameters:
    ///   - focus: windows of the frontmost application to put in front of
    ///     `windows`. The default places focus on the secondary display, so that
    ///     a click on the primary display crosses displays; pass `[]` when the
    ///     fixture arranges focus itself.
    ///   - dockSilent: true to make the Dock fail to answer.
    private func act(_ point: CGPoint, _ windows: [WindowSnapshot],
                     frontmostPID: pid_t? = nil, frontmostIsSystemUI: Bool = false,
                     modifiers: CGEventFlags = [], dockStrip: CGRect = .null,
                     dockShowsStack: Bool = false, dockSilent: Bool = false,
                     notificationRects: [CGRect] = [],
                     focus: [WindowSnapshot]? = nil,
                     screens: [ScreenInfo]? = nil) -> ClickAction {
        WindowFinder.action(for: point,
                            windows: { (focus ?? [self.focusOnSecondary]) + windows },
                            frontmostPID: frontmostPID ?? frontPID,
                            frontmostIsSystemUI: frontmostIsSystemUI,
                            screens: screens ?? self.screens,
                            ownPID: ownPID,
                            modifiers: modifiers,
                            dockState: { _ in
                                dockSilent ? nil : DockState(strip: dockStrip, showsStack: dockShowsStack)
                            },
                            notificationRects: { _, _ in notificationRects })
    }

    // MARK: - Only across displays

    /// The rule the whole utility now hangs on: a click that does not move focus
    /// to another display is macOS's business, not this app's.
    func testClickWithinTheFocusedDisplayIsLeftToMacOS() {
        let inactive = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertEqual(act(CGPoint(x: 200, y: 200), [inactive], focus: [focusOnPrimary]),
                       .ignore(.sameDisplay))
    }

    /// Which means a machine with one display never sees it do anything at all.
    func testSingleDisplaySetupIsNeverTouched() {
        let inactive = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertEqual(act(CGPoint(x: 200, y: 200), [inactive],
                           focus: [focusOnPrimary], screens: [primary]),
                       .ignore(.sameDisplay))
    }

    func testClickOnTheActiveWindowIsLeftAlone() {
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [fullWindow(pid: frontPID, id: 1)], focus: []),
                       .ignore(.sameDisplay))
    }

    /// A window straddling two displays belongs to the one showing more of it,
    /// so clicking the part of it that hangs onto the other display does count
    /// as crossing displays - and is then caught by the rule below it, because
    /// it is already the active window.
    func testStraddlingWindowBelongsToTheDisplayShowingMostOfIt() {
        let straddling = window(pid: frontPID, id: 1,
                                rect: CGRect(x: 100, y: -600, width: 800, height: 1000))
        XCTAssertEqual(act(CGPoint(x: 400, y: 200), [straddling], focus: []),
                       .ignore(.alreadyFrontWindow))
    }

    /// The frontmost application does not always have a window - Finder has none
    /// after a click on the desktop - and the click still has to work, otherwise
    /// clicking the wallpaper would switch the utility off until the next
    /// activation.
    func testFocusFallsBackToTheTopmostWindowWhenTheFrontApplicationHasNone() {
        let topmost = window(pid: 30, id: 5, rect: CGRect(x: -100, y: -900, width: 800, height: 600))
        let target = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [topmost, target], frontmostPID: 77, focus: []),
                       .activate(pid: otherPID, windowID: 2, windowBounds: target.bounds,
                                 raiseWindow: false))
    }

    func testNothingOnScreenLeavesTheClickAlone() {
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [], focus: []), .ignore(.focusDisplayUnknown))
    }

    // MARK: - Core behaviour

    func testClickOnInactiveApplicationActivatesIt() {
        let inactive = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertEqual(act(CGPoint(x: 200, y: 200), [inactive]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: inactive.bounds, raiseWindow: false))
    }

    /// Clicking the *frontmost* application's window on another display must
    /// focus that window, not leave the click to be eaten by the window becoming
    /// key.
    func testClickOnBackgroundWindowOfActiveApplicationRaisesThatWindow() {
        let back = window(pid: frontPID, id: 2, rect: CGRect(x: 900, y: 600, width: 400, height: 300))
        XCTAssertEqual(act(CGPoint(x: 1000, y: 700), [back]),
                       .activate(pid: frontPID, windowID: 2, windowBounds: back.bounds, raiseWindow: true))
    }

    /// When an inactive app has several windows, the clicked one - not whichever
    /// happens to be that app's front window - must come forward.
    func testClickOnBackgroundWindowOfInactiveApplicationRaisesTheClickedWindow() {
        let appFront = window(pid: otherPID, id: 2, rect: CGRect(x: 100, y: 100, width: 300, height: 200))
        let appBack = window(pid: otherPID, id: 3, rect: CGRect(x: 600, y: 400, width: 300, height: 200))
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [appFront, appBack]),
                       .activate(pid: otherPID, windowID: 3, windowBounds: appBack.bounds, raiseWindow: true))
    }

    // MARK: - Multiple displays

    func testWindowOnSecondaryDisplayWithNegativeCoordinates() {
        let onSecondary = window(pid: otherPID, id: 2, rect: CGRect(x: -100, y: -900, width: 800, height: 600))
        XCTAssertEqual(act(CGPoint(x: 100, y: -600), [onSecondary], focus: [focusOnPrimary]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: onSecondary.bounds, raiseWindow: false))
    }

    func testPointOnNoDisplayFindsNoWindow() {
        XCTAssertEqual(act(CGPoint(x: 5000, y: 5000), [fullWindow(pid: otherPID, id: 2)]),
                       .ignore(.noWindowUnderCursor))
    }

    func testMenuBarStripIsIgnored() {
        let windows = [primaryMenuBar, dockBackdrop, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 700, y: 10), windows), .ignore(.menuBarOrDock))
    }

    func testMenuBarOnSecondaryDisplayIsIgnored() {
        let onSecondary = window(pid: otherPID, id: 2,
                                 rect: CGRect(x: -200, y: -1080, width: 1920, height: 400))
        XCTAssertEqual(act(CGPoint(x: 700, y: -1070), [secondaryMenuBar, onSecondary],
                           focus: [focusOnPrimary]),
                       .ignore(.menuBarOrDock))
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows, dockStrip: dockStrip,
                           screens: [noInset, secondary]),
                       .ignore(.menuBarOrDock))
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), windows, dockSilent: true),
                       .ignore(.menuBarOrDock))
    }

    /// A full-screen window covers the Dock, and macOS takes the Dock's window
    /// out of the on-screen list for that display. The bottom strip is then part
    /// of the window - where a video player keeps its controls - so the click
    /// must be delivered rather than written off as a Dock click.
    func testDockStripBelongsToAFullScreenWindowWhenTheDockIsNotOnScreen() {
        let fullScreen = window(pid: otherPID, id: 2,
                                rect: CGRect(x: 0, y: 33, width: 1512, height: 949))
        XCTAssertEqual(act(CGPoint(x: 700, y: 950), [primaryMenuBar, fullScreen]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: fullScreen.bounds,
                                 raiseWindow: false))
    }

    /// Same again for the menu bar strip macOS reserves on every display: a
    /// full-screen window on the secondary display covers it, and the window
    /// server stops drawing a menu bar there.
    func testReservedMenuBarStripBelongsToAFullScreenWindowOnASecondaryDisplay() {
        let fullScreen = window(pid: otherPID, id: 2,
                                rect: CGRect(x: -200, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(act(CGPoint(x: 700, y: -1070), [fullScreen], focus: [focusOnPrimary]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: fullScreen.bounds,
                                 raiseWindow: false))
    }

    // MARK: - System and special UI

    func testMissionControlAndOtherSystemUIAreIgnored() {
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [fullWindow(pid: otherPID, id: 2)],
                           frontmostIsSystemUI: true),
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [backdrop, dockBackdrop, app]),
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [menu, fullWindow(pid: otherPID, id: 2)]),
                       .ignore(.menuOpen))
    }

    func testFloatingPanelAboveTheWindowSuppressesActivation() {
        let panel = window(pid: frontPID, id: 8, rect: CGRect(x: 600, y: 400, width: 300, height: 200), layer: 3)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [panel, fullWindow(pid: otherPID, id: 2)]),
                       .ignore(.overlayWindow))
    }

    /// The Dock and Notification Center each keep a window covering the whole
    /// display above ordinary windows, and the window server owns the pointer
    /// overlay, which is under the cursor by definition. None may hide the
    /// application window beneath.
    func testSystemBackdropsAndCursorOverlayAreTransparentToTargeting() {
        let cursor = window(pid: 2, id: 31, rect: CGRect(x: 695, y: 495, width: 28, height: 40),
                            layer: 2147483630, owner: WindowFinder.windowServerOwnerName)
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [cursor, notificationBackdrop, dockBackdrop, app]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// A small overlay from the same processes is still respected: it is real UI.
    func testSmallSystemOverlayStillSuppressesActivation() {
        let banner = window(pid: 4, id: 33, rect: CGRect(x: 1100, y: 40, width: 360, height: 100),
                            layer: 21, owner: WindowFinder.notificationCenterOwnerName)
        XCTAssertEqual(act(CGPoint(x: 1200, y: 80), [banner, fullWindow(pid: otherPID, id: 2)]),
                       .ignore(.overlayWindow))
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [fullWindow(pid: ownPID, id: 60)]),
                       .ignore(.ownApplication))
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
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [primaryMenuBar, dockBackdrop, app],
                           dockShowsStack: false),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// The Dock only covers its own display, so an open stack there cannot be a
    /// reason to suppress a click on a different display.
    func testDockStackDoesNotSuppressClicksOnAnotherDisplay() {
        let onSecondary = window(pid: otherPID, id: 2,
                                 rect: CGRect(x: -100, y: -900, width: 800, height: 600))
        XCTAssertEqual(act(CGPoint(x: 100, y: -600), [primaryMenuBar, dockBackdrop, onSecondary],
                           dockShowsStack: true, focus: [focusOnPrimary]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: onSecondary.bounds,
                                 raiseWindow: false))
    }

    // MARK: - Notifications

    /// The reported bug: a notification, and the close button that appears on it
    /// when the pointer is over it, are drawn inside a window that covers the
    /// whole display, so clicking the close button used to bring the window
    /// behind the notification forward.
    func testClickOnANotificationIsLeftAlone() {
        let windows = [notificationBackdrop, dockBackdrop, fullWindow(pid: otherPID, id: 2)]
        XCTAssertEqual(act(CGPoint(x: 1170, y: 60), windows, notificationRects: [notificationBanner]),
                       .ignore(.notificationContent))
    }

    /// And the other half of that: the rest of the display is not Notification
    /// Center's, even while it has a banner up, so a click there still works.
    func testClickBesideANotificationStillActivates() {
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [notificationBackdrop, app],
                           notificationRects: [notificationBanner]),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    /// If Notification Center does not answer, or is drawing nothing that can be
    /// clicked, the click belongs to the window underneath. Silence must not turn
    /// into "ignore everything on this display".
    func testNotificationCenterSilenceLeavesTheClickToTheWindow() {
        let app = fullWindow(pid: otherPID, id: 2)
        XCTAssertEqual(act(CGPoint(x: 1170, y: 60), [notificationBackdrop, app],
                           notificationRects: []),
                       .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
    }

    // MARK: - Modifiers

    func testCommandClickIsLeftToMacOS() {
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [fullWindow(pid: otherPID, id: 2)],
                           modifiers: .maskCommand),
                       .ignore(.modifierHeld))
    }

    func testControlClickIsLeftToMacOS() {
        XCTAssertEqual(act(CGPoint(x: 700, y: 500), [fullWindow(pid: otherPID, id: 2)],
                           modifiers: .maskControl),
                       .ignore(.modifierHeld))
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
                                        windows: {
                                            reads += 1
                                            return [self.focusOnSecondary, self.primaryMenuBar,
                                                    self.dockBackdrop, app]
                                        },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in DockState(strip: self.dockStrip, showsStack: false) })
        XCTAssertEqual(action, .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
        XCTAssertEqual(reads, 1)
    }

    /// The everyday click - one that stays on the display that already has focus
    /// - must cost the window-list read and nothing else: no Accessibility round
    /// trip to the Dock or to Notification Center, and no activation.
    func testSameDisplayClickCostsOnlyTheWindowListRead() {
        var reads = 0
        var dockAsked = 0
        var centreAsked = 0
        let app = fullWindow(pid: otherPID, id: 2)
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 500),
                                        windows: {
                                            reads += 1
                                            return [self.focusOnPrimary, self.primaryMenuBar,
                                                    self.dockBackdrop, self.notificationBackdrop, app]
                                        },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in dockAsked += 1; return nil },
                                        notificationRects: { _, _ in centreAsked += 1; return [] })
        XCTAssertEqual(action, .ignore(.sameDisplay))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(dockAsked, 0)
        XCTAssertEqual(centreAsked, 0)
    }

    /// Asking a system process where its own UI is costs Accessibility round
    /// trips, so neither the Dock nor Notification Center may be asked unless its
    /// own window is actually over the click.
    func testSystemProcessesAreOnlyAskedWhenTheirWindowCoversTheClick() {
        var dockAsked = 0
        var centreAsked = 0
        let app = fullWindow(pid: otherPID, id: 2)
        let action = WindowFinder.action(for: CGPoint(x: 700, y: 500),
                                        windows: { [self.focusOnSecondary, app] },
                                        frontmostPID: frontPID,
                                        frontmostIsSystemUI: false,
                                        screens: screens,
                                        ownPID: ownPID,
                                        modifiers: [],
                                        dockState: { _ in dockAsked += 1; return nil },
                                        notificationRects: { _, _ in centreAsked += 1; return [] })
        XCTAssertEqual(action, .activate(pid: otherPID, windowID: 2, windowBounds: app.bounds, raiseWindow: false))
        XCTAssertEqual(dockAsked, 0)
        XCTAssertEqual(centreAsked, 0)
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
