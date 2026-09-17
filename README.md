# ClickThrough

A menu bar utility that stops macOS wasting the first click on an inactive window.

Normally, clicking a control in a window that is not the active window only
activates that window; the click itself is discarded and you have to click
again. ClickThrough activates the window's application *before* the click is
delivered, so the click lands where you aimed it. One physical click, one action.

It is **not** focus-follows-mouse: moving the pointer over a window does nothing.
Only an actual click activates anything.

## Install

Download the latest `.dmg` from [Releases](https://github.com/PirouzSR/ClickThrough/releases/latest),
open it and drag **ClickThrough** to Applications. That build is ad-hoc signed
and not notarized, so the first launch needs right-click › **Open** › Open.
It is Apple silicon only; on Intel, build from source.

To build it yourself instead:

1. ```
   ./scripts/build-release.sh
   ```

   (or open `ClickThrough.xcodeproj` in Xcode and build the `ClickThrough` scheme)

2. Drag `build/ClickThrough.app` to `/Applications`.

Either way, then:

3. Launch it once. macOS will ask for Accessibility permission — grant it in
   System Settings › Privacy & Security › Accessibility.
4. Done. It registers itself as a login item, so it starts automatically from
   then on.

`./scripts/make-dmg.sh` produces `build/ClickThrough.dmg` with a
drag-to-Applications layout if you prefer to install that way.

## Using it

The menu bar icon is the entire interface:

<img src="docs/menu.png" width="202" alt="The ClickThrough menu: Enabled (checked), Quit ClickThrough">

* **Enabled** toggles interception. When off, the event tap is torn down and
  macOS behaves exactly as it normally does. The setting persists across launches
  and defaults to on.
* The icon is slashed when disabled, and dimmed when it is enabled but cannot
  work because Accessibility permission is missing. An **Open Accessibility
  Settings…** item appears in the menu only in that case.

There are no other settings.

## How it works

A `CGEventTap` watches left mouse-down. For each one:

1. Read the on-screen window list (front to back) and find the topmost ordinary
   window under the pointer.
2. If that window's application is already frontmost and the window is already
   its front window, do nothing.
3. Otherwise activate that application — raising the specific clicked window
   first if it is not already that application's front window — wait until the
   application reports that it really is frontmost, and then return **the
   original event, unmodified**.

The application therefore receives the user's real click at a moment when it is
already active, so AppKit delivers it to the view instead of swallowing it as an
activation click.

Step 3 has to wait, not just ask. `activate()` only *requests* activation; if
the held mouse-down is released before the application has actually become
active, AppKit still treats it as the activating click and discards it. That
race is easy to lose when the clicked window is on a second display, where
activation is measurably slower — on a two-monitor setup, not waiting lost
roughly one click in five. The wait has a hard time budget (200 ms, plus at most
one Accessibility timeout) so a hung application can never stall the mouse or
push the callback past the event tap's own one-second limit; in practice an
activating click costs ~13 ms.

No synthetic clicks are ever generated, and no event is ever suppressed. That is
what guarantees one physical click can never become two logical actions.

### Deliberate non-interference

A click is passed through untouched when:

* **Command or Control is held.** ⌘-click already means "interact without
  activating" and ⌃-click means "context menu"; both are left to macOS.
* **A menu is open anywhere** (any window at the pop-up-menu level). A click
  then is a dismissal gesture, not an intent to activate something underneath.
* **The pointer is outside the screen's visible frame** — the menu bar or the Dock.
* **The frontmost application is system UI** — Mission Control, Launchpad, a Dock
  menu, the login window or a screen saver.
* **The topmost window under the pointer is not an ordinary window** — a panel,
  popover, tooltip, HUD or system overlay.
* The window belongs to ClickThrough itself, or to a process that cannot be
  activated.

Two window-server details the targeting has to allow for, both observed on
macOS 27: **the Dock and Notification Centre each keep a window covering an
entire display** above ordinary windows, and **the mouse pointer is itself a
window**, directly under the cursor at all times. Treating either as "the
window you clicked" would make the utility a silent no-op — intermittently, in
Notification Centre's case. Any window above the ordinary level that spans a
whole display is therefore treated as a backdrop and looked through.

### Multiple displays

All geometry is handled in Core Graphics global coordinates — the same space
used by both `CGEvent.location` and `kCGWindowBounds`. Displays at negative
offsets, different resolutions and different scale factors therefore need no
special handling. The display layout is re-read on screen-configuration changes
and on wake.

## Permissions

Accessibility only. It is required to create an event tap and to raise a
specific window. The app requests nothing else — no Screen Recording (which is
why window *titles* are never read), no network, no file access. It is not
sandboxed, because a global event tap cannot be.

If permission is missing the app still runs, the menu bar icon still appears and
the toggle still works; it simply does not intercept anything until permission is
granted, which it notices within a couple of seconds without needing a restart.

## Requirements and compatibility

* macOS 13 or later (built and verified on macOS 27).
* No third-party dependencies of any kind; Apple frameworks only.
* Swift 6 language mode, strict concurrency enabled.

## Known limitations

* **Applications that explicitly discard clicks received while inactive** cannot
  be fixed this way, because the decision happens inside that app after the
  event is delivered. Pre-activation handles every standard AppKit view tested.
* **Always-on-top windows** (floating panel level) are intentionally not targets.
* The first click after the Dock is revealed from auto-hide may activate the
  window behind it. The click still goes to the Dock — only the activation is
  spurious.

## Building and Gatekeeper

`scripts/build-release.sh` uses `xcodebuild` when available and otherwise falls
back to `scripts/build-app.sh`, which drives `swiftc` directly and produces the
same bundle.

If you see *"You have not agreed to the Xcode license agreements"*, run:

```
sudo xcodebuild -license accept
```

The app is signed **ad-hoc** (`codesign --sign -`), which is enough to run it
locally and to give it a stable identity for the Accessibility permission. Two
consequences:

* An ad-hoc signed app is not notarized, so if you move the `.app` or `.dmg` to
  another Mac, Gatekeeper will block it until you right-click › Open once.
* Rebuilding produces a new signature, which can make macOS treat it as a
  different app. If it stops intercepting after a rebuild, remove it from
  System Settings › Privacy & Security › Accessibility and add it again.

To ship it properly, set a Development Team in the Xcode project and notarize
the result.

## Uninstall

Quit from the menu bar, then delete `/Applications/ClickThrough.app`. To also
remove the login-item registration, switch it off in System Settings › General ›
Login Items before deleting (the same place you can confirm it registered).

## Layout

```
ClickThrough/
  main.swift                  entry point
  AppDelegate.swift           lifecycle, single-instance guard, wiring
  ClickThroughController.swift  owns the tap, caches what the hot path needs
  EventTap.swift              tap lifecycle on its own thread, re-arming
  WindowFinder.swift          window under cursor + the pass/activate policy
  WindowActivator.swift       activation and window raising
  ScreenGeometry.swift        display layout in CG coordinates
  StatusBarController.swift   the menu bar item
  AccessibilityManager.swift  permission state
  LoginItemManager.swift      SMAppService registration
  Log.swift                   logging, verbose only in debug builds
ClickThroughTests/            unit tests for the click policy
scripts/                      build and packaging
```

## License

MIT — see [LICENSE](LICENSE).
