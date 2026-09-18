# Testing

## Automated

`ClickThroughTests/WindowFinderTests.swift` covers the click policy, which is a
pure function and therefore testable without a window server. 45 tests: the
cross-display rule itself (same display, single display, straddling windows,
focus falling back to the topmost window when the frontmost application has
none, nothing on screen at all), active vs inactive windows, background windows
of the active and of an inactive application, negative-coordinate secondary
displays, the menu bar on either display, the Dock strip (ordinary,
auto-hidden, hidden, and when Accessibility does not answer), the strips a
full-screen window covers, open menus, floating panels, the Dock backdrop and
cursor overlay, Dock stacks, notifications (on a banner, beside one, and when
Notification Center says nothing), Mission Control versus the wallpaper-click
state, fully transparent windows, desktop windows, own windows, modifiers, the
cost rules - the window list read lazily and exactly once, and neither the Dock
nor Notification Center asked unless its own window is over the click - and the
AppKit→CoreGraphics coordinate flip.

Because the policy now acts only on a click that crosses displays, nearly every
fixture includes a window of the frontmost application on the *other* display;
`act(...)` adds one by default. A fixture without it is testing what happens
when the click does not cross displays.

```
xcodebuild -project ClickThrough.xcodeproj -scheme ClickThrough test
```

The suite can also be run without Xcode's build system, which is how it was run
here - build the sources as a testable module, link the tests as a bundle, and
run them with Xcode's `xctest`:

```
XC=/Applications/Xcode.app/Contents/Developer
SW=$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=$XC/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
XCF=$XC/Platforms/MacOSX.platform/Developer/Library/Frameworks
XCI=$XC/Platforms/MacOSX.platform/Developer/usr/lib
mkdir -p /tmp/ct && SRC=(ClickThrough/*.swift) && SRC=(${SRC:#*main.swift})
$SW -sdk $SDK -swift-version 6 -module-name ClickThrough -enable-testing \
    -emit-module -emit-library -emit-module-path /tmp/ct/ClickThrough.swiftmodule \
    -o /tmp/ct/libClickThrough.dylib \
    -Xlinker -install_name -Xlinker @rpath/libClickThrough.dylib "${SRC[@]}"
B=/tmp/ct/ClickThroughTests.xctest && mkdir -p $B/Contents/MacOS
$SW -sdk $SDK -swift-version 6 -module-name ClickThroughTests -emit-library \
    -I /tmp/ct -I $XCI -L /tmp/ct -L $XCI -lClickThrough -F $XCF -framework XCTest \
    -Xlinker -bundle -Xlinker -rpath -Xlinker @loader_path/../../.. \
    -Xlinker -rpath -Xlinker $XCF \
    -o $B/Contents/MacOS/ClickThroughTests ClickThroughTests/*.swift
printf '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>ClickThroughTests</string></dict></plist>' > $B/Contents/Info.plist
DYLD_FRAMEWORK_PATH=$XCF DYLD_LIBRARY_PATH=/tmp/ct $XC/usr/bin/xctest $B
```



## Performance

Profiled with the shipping engine, 42 clicks and a 200-event drag, on a
two-display setup:

| | median | p90 | max |
|---|---|---|---|
| Window-server query (`CGWindowListCopyWindowInfo`) | 957 µs | 1757 µs | 3194 µs |
| Policy decision | 5 µs | 6 µs | 27 µs |
| Drag event pass-through | ~0 µs | 1 µs | 1 µs |

Idle: 0.020 s of CPU over 90 s of wall time, 0.02% of one core, 15 MB
`phys_footprint`, 10 threads. Per-click debug logging is confirmed absent from
the release binary - none of the format strings appear in it.

These are from the third round, and the window-server figures include cold
reads, which is why they are higher than the warm per-call numbers in the fourth
round below. What changed since: an ordinary click that stays on the display
that has focus now costs that one query and 1 µs, and nothing else at all.

So one window-server query is ~99.5% of the cost of an ordinary click, and the
decision logic is 0.5%. That ruled several things in and out:

- **Read the window list lazily** - done. A ⌘-click or ⌃-click, and any click
  while the system is showing its own UI, is decided from the modifier flags and
  the cached frontmost application alone. Measured afterwards at 0.0-0.1 ms with
  no query at all, against ~1 ms before. Three unit tests pin this down,
  including that the list is read exactly once when it *is* needed.
- **Find the clicked Accessibility window once, not twice** - done. The window
  has to be raised both before and after activating, and each search costs a
  round trip per window of that application. Reusing the element took the time
  spent before the wait from 34-37 ms to 19-22 ms for a browser with two
  windows. It is also more correct: an element keeps referring to the same
  window even if it moves, where a second frame match might not.
- **Hand-rolled CoreFoundation decoding instead of bridging to Swift
  dictionaries** - measured and rejected. Bridging is only ~33 µs of the query,
  and a CF version saved ~49 µs, about 5% of a click, in exchange for
  `unsafeBitCast` throughout the one function that has to be right.
- **Fusing the policy's several passes over the window list** - rejected. It
  would save a few microseconds of the 5 µs the policy takes.
- **Caching the window list between clicks** - rejected. It would save ~1 ms on
  the second click of a double-click, at the cost of acting on stale geometry,
  which is exactly the class of bug this utility keeps hitting.
- **Dropping mouse-up and mouse-dragged from the tap's mask** - rejected. They
  cost ~1 µs each and are what keeps a held mouse-down from being overtaken by
  the events that follow it.

## Fourth round: narrowing the scope to clicks that cross displays

Two things prompted this round. A click on a notification's close button was
being pushed through to the window behind the notification; and that was the
fourth bug of the same shape - a system surface drawn into a window covering a
whole display, which the targeting rule looks past. The fix for the shape, not
just the instance, was to stop acting on clicks that do not cross displays at
all.

### The mechanism behind the notification bug

`CGWindowListCopyWindowInfo` with a banner on screen:

```
id=67  pid=741  layer=21  Notification Center  x=0 y=0 w=1512 h=982
```

One window over the whole display, at a level above ordinary windows, owned by a
process that never becomes frontmost - the Dock's problem exactly. The banner
itself occupies 344x58 of it. Clicking the close button therefore activated
whatever window lay under the rest of that window.

Opening the notification panel from the clock produces the same window. Control
Center, checked at the same time, does *not*: it opens a 656x967 window at level
101, which the existing open-menu rule already covers.

Where the banner actually is, from Notification Center's Accessibility
hierarchy - and it agrees with the system hit test, `AXUIElementCopyElement`
`AtPosition` at a point inside it returning the banner and at a point 12pt to
its left returning the application underneath:

```
AXWindow/AXSystemDialog                     x=0    y=0  w=1512 h=982
  AXGroup/AXHostingView                     x=0    y=0  w=1512 h=982
    AXGroup                                 x=760  y=0  w=752  h=868
      AXScrollArea                          x=760  y=0  w=752  h=868
        AXGroup/AXNotificationCenterBanner  x=1152 y=49 w=344  h=58
```

The close button is not exposed as an element of its own; it is drawn inside the
banner's rectangle, which is why taking the banner is enough. Only geometry is
read - no titles, no descriptions.

### Where notifications appear, which decides whether the scope change alone was enough

It was not. With focus on the secondary display, a notification still appears on
the primary one, so a click on it crosses displays and reaches the policy:

```
focus on the secondary display (a window activated there)
notification window: x=0 y=0 w=1512 h=982     <- the primary display
```

So both fixes were needed: the cross-display rule, and asking Notification
Center where it is drawing.

### The test rig

Three scratch applications, each an unbundled AppKit binary:

* `harness <label> <screen> <seconds> <slot>` - a window on a chosen display
  whose view reports on stdout when it receives a `mouseDown`. Its view does not
  accept the first mouse, so an inactive window swallows the activating click -
  which is exactly the wasted click being measured. Slot 2 covers the whole
  display, for putting a window under a notification.
* `twin <label> <seconds>` - one application with a window on *every* display:
  the shape of the problem case (a browser with a window per screen).
* `click`, `move`, `front`, `dump`, `above`, `nc`, `at` - synthetic click and
  pointer moves, the frontmost application, the window list, what the window
  server reports *above* a given window, Notification Center's hierarchy, and
  the system-wide element at a point.

A trap worth recording: `harness` originally did not call
`NSApp.activate(ignoringOtherApps:)`, and a window ordered front by an inactive
application stays *behind* the active application's windows. It was in the
on-screen window list at the right coordinates and every click on it went to the
editor covering the display instead. `CGWindowListCopyWindowInfo` with
`.optionOnScreenAboveWindow` is the way to check this rather than eyeballing the
front-to-back list.

### Click delivery, measured

Same script, three configurations. "Delivered" means the window's view received
the `mouseDown`, not merely that the application came forward.

| click | ClickThrough stopped | 1.2.1 | 1.3.0 |
|---|---|---|---|
| inactive window, same display as focus | no | **yes** | no |
| inactive window, another display | no | yes | **yes** |
| window that is already active | yes | yes | yes |

The middle row is the deliberate change: within one display the utility now
behaves exactly as if it were not running. The bottom two rows are what had to
keep working.

### The notification fix, measured

Focus on the secondary display, a window of `harness A` covering the primary
display, a notification posted, the pointer moved onto the banner and its close
button clicked. The two arms differ only in whether the policy is given
Notification Center's rectangles:

| | harness A activated by the click | notification dismissed |
|---|---|---|
| Notification Center rule disabled | **yes** - the reported bug | yes |
| 1.3.0 | no | yes |

Since nothing else in the policy would leave that click alone, "not activated"
is also proof that the shipping walk really does find the live banner.

### Focusing is not raising

Found while checking that the multi-display fix still held. With `twin` - one
application, a window on each display - the cross-display click was *not*
delivered, and the debug log said why:

```
activate pid=17197 window=1808 raise=true at (1070.0, -394.0)
activate: target not ready within budget (frontmost: true)
```

The application became frontmost but never made the clicked window its focused
window, so AppKit discarded the click. `AXRaise` only changes the z-order;
Chrome treats being raised as being focused and an ordinary AppKit application
does not, which is why eight rounds of measurement against a browser never
showed it. It was not a regression - 1.2.1, rebuilt from its own commit in a
worktree and installed, failed identically.

Setting `kAXMain` and `kAXFocused` on the clicked window fixed it, but only
4 times in 5: activation is asynchronous, so the application can focus its own
last-used window *after* being asked for the clicked one, and every failure
coincided with the budget expiring. Re-asserting the request every 30 ms while
waiting closed it.

| | clicks delivered | wait budget exceeded |
|---|---|---|
| raise only (1.2.1 and 1.3.0 before this) | 0 / 3 | 3 / 3 |
| raise + focus, asked once | 4 / 5 | 1 / 5 |
| raise + focus, re-asserted every 30 ms | **12 / 12** | 0 / 12 |

The displaced-window restore was ruled out as the cause on the way - disabling
it changed nothing about delivery, and confirmed it is still doing its job: with
it disabled the two-display application's other window jumped over the window
that had focus, and with it enabled that window stayed on top.

### Cost after the change

Policy function against a live 10-window, 2-display list:

| | per call |
|---|---|
| Window-list read (`CGWindowListCopyWindowInfo`, warm) | 288 µs |
| Policy, click on the display that has focus | 1.1 µs |
| Policy, click that crosses displays | 6.0 µs |
| Policy, ⌘-click (decided before the list is read) | 0.0 µs |

The everyday click is now the first of those: one window-server read, no
Accessibility round trip to any other process, no activation, nothing held. The
scope change is the largest saving made so far - it removed 13-40 ms of blocking
work from every same-display click on an inactive window.

## Third round: the multi-display case the utility was actually for

Reported: with an editor on the laptop display and a browser window on the
external one, clicking the browser did nothing except bring the browser's
*other* window forward over the editor. Both halves of that were real, and the
second half was caused by this utility.

The cause is what activation does. `NSRunningApplication.activate()` does not
just make an application frontmost; the application then focuses and raises
*its own* last-used window. For a browser holding a window on each display that
window is the one on the other display, so:

- the raise this utility had just performed on the clicked window was thrown
  away, the clicked window was not the focused one when the mouse-down was
  released, and the click was discarded exactly as if nothing were running;
- the browser's window on the *other* display was raised over whatever the user
  had there.

Six strategies were measured against a real browser window on the external
display, with the browser's laptop-side window as its main window, the user in
another application, and the click counted by the page itself:

| strategy | click delivered | other display disturbed |
|---|---|---|
| stock macOS, nothing running | 0/8 | 0/8 |
| raise, then activate (what 1.1.0 did) | 0/8 | 8/8 |
| raise only, never activate | 0/8 | 0/8 |
| set `AXFocused` on the window, no activate | 0/6 | 0/6 |
| set `AXFocused`, then make the app frontmost | 0/8 | 8/8 |
| set `AXMain` on the window, then activate | 1/8 | 7/8 |
| raise, activate, raise again | 6/8 | 7/8 |
| raise, activate, raise again, restore the other display once | 4/8 | 6/8 |
| **raise, activate, raise again, restore repeatedly** | **8/8** | **0/8** |

Two things had to be true at once, and each needed its own fix:

1. **Raise again after activating.** Anything done before the activation is
   discarded by the application's own window handling. Raising once more
   afterwards is what makes the clicked window the focused one in time.
2. **Put back what the activation displaced.** For every display other than the
   clicked one, the window that was on top there is raised again - immediately
   and then at 40, 130 and 310 ms, because the application raises its own window
   slightly *after* it is activated, so a single attempt loses the race.
   Raising a window does not change which application is active, so this does
   not undo the activation the click depends on.

The utility also now waits for the *clicked window* to be the application's
focused window rather than merely for the application to be frontmost.
`kAXFrontmost` goes true while the application is still settling, which is why
the previous version reported success on every one of the clicks it lost.

Measured after the fix, with the real engine: **10/10 delivered, 0/10 other
displays disturbed**, focus confirmed on every click, worst callback 25 ms.
Cross-display delivery against a plain `NSView` probe went from 0/5 to 6/6 in
both directions, with fast clicks and drags at 4/4, and no tap disables.

### A measurement trap worth recording

The first pass through this investigation concluded the opposite - that the
utility worked and stock macOS was the one raising windows. That was wrong, and
the cause was leaked test processes: each experiment installed its own event tap
and `pkill` with a path pattern never matched them, so twenty-one taps
accumulated, every one of them activating applications on each click. Any
measurement of "what happens on a click" is meaningless without first checking
what else is tapping. `CGGetEventTapList` reports every tap in the session with
its owning process, and is now the first thing to check.

## Second round: edge cases found after release

Reported symptoms were (a) the utility occasionally stopping completely while
Chrome on a second display was used alongside an editor on the first, and (b)
clicking a file in a Dock stack selecting the window behind it instead. Both
turned out to be real, and hunting for them turned up four more.

Everything below was measured with the shipping engine, driven by synthetic
clicks, with the engine's own decision for each click read out of its debug log.

| Defect | How it showed up | Cause |
|---|---|---|
| **Dock stacks** | Clicking a file in the fan from a Dock folder activated and raised the window behind the Dock | The fan is drawn *inside* the Dock's full-display window, which the backdrop rule deliberately looks past, and the Dock does not become frontmost while a stack is open. Neither signal the utility used could see it |
| **Full-screen windows lost clicks near two edges** | Clicks in the bottom ~92 pt of a full-screen window on the primary display, and the top 30 pt on the secondary, were discarded | macOS reserves the menu bar and Dock strips in `NSScreen.visibleFrame` permanently, whether or not either is on screen. A full-screen window covers them. This is where a video player keeps its controls, which matches the reported second-display symptom |
| **Auto-hidden Dock** | With the Dock set to hide, clicking the revealed Dock activated and raised the window behind it | With auto-hide there is no reserved inset in `visibleFrame` at all, so the strip test could not fire |
| **Mission Control** | Clicking during Mission Control activated whichever window lay under the pointer | It is owned by `WindowManager`, does not become the frontmost application, and covers each display with a window the backdrop rule looks past |
| **Recovery from a disabled tap took up to 15 s** | The utility dead for seconds, or until restarted | The window server disables a tap whose callback runs long, and delivers the "disabled" event only when the *next* event is routed - so a tap can sit disabled with no callback coming. The watchdog that recovers it ran every 15 s |
| **The debug configuration did not compile** | Only visible if you built it | `Log.debug` passed an `@autoclosure` into os_log's escaping interpolation. The body is `#if DEBUG`, so release builds never saw it |

The fixes replace guesses about where system UI is with the system's own
answers:

- the **menu bar** is taken from the window list. The window server keeps a menu
  bar window only on a display that is really showing one, and removes it for a
  display covered by a full-screen window - unlike `visibleFrame`, which always
  reserves the strip;
- the **Dock strip** is whatever frame the Dock reports for its own list of
  items. That frame follows the Dock to the left or right edge, grows with the
  icon size, and sits below the bottom of the display while the Dock is hidden,
  so auto-hide needs no special case. `visibleFrame` is kept only as a fallback
  for when Accessibility does not answer;
- an **open Dock stack** is read from the Dock, which reports a focused element
  while one is being tracked;
- the Dock is only asked at all for a click that would otherwise activate
  something, and only when the Dock's own window covers that click, so the
  common case pays nothing. Measured at ~0.1 ms warm, against ~25 ms for the
  first call - which is now paid at launch.

### Measurements after the fixes

| Check | Result |
|---|---|
| Two displays, alternating clicks on a plain `NSView` in an inactive window, both directions | 40/40 delivered, 0 lost, 0 duplicated |
| Same with a 5 ms mouse-down, and with a drag begun on the inactive window | 24/24 delivered |
| Single, double, 5 ms, drag, and ten rapid clicks | Exactly 1, 2, 1, 1 and 10 mouse-downs - one physical click is never two logical ones |
| Clicks in the Dock-strip region of a full-screen window (previously lost) | 5/5 delivered; 10/10 over three probes in the final pass |
| Dock icon over a window, ordinary Dock / auto-hidden and revealed / Dock on the left edge | Left alone in all three; the window behind is not raised |
| Dock stack: click a fan item, and drag a file out of the fan | Left alone; focus stays where it was and `~/Downloads` is unchanged |
| Menu bar on either display, empty desktop, ⌘-click, ⌃-click | Left alone. ⇧-click still activates |
| Mission Control up / wallpaper-click state | Left alone / activates normally |
| Live display rearrangement, Stage Manager on, Space switch | Adapts; no false suppression |
| Event tap health over ~250 driven clicks | No disables; worst callback 33 ms against a 1-1.5 s budget; every activation confirmed before the click was released |
| Recovery after the system disables the tap | 90-620 ms, against up to 15 s before |

Two things worth being explicit about:

- **A spontaneous total stoppage was never reproduced.** Chrome on the second
  display with an editor on the first was driven hard without one. What was
  found is a mechanism that produces exactly that symptom - a tap left disabled
  with no callback coming - and the window in which it is possible is now under
  a second rather than up to fifteen.
- The tap callback budget was measured directly, by blocking it on purpose: no
  disable at 1000 ms, disabled at 1500 ms. The activation wait is capped at
  200 ms, so it has roughly five times the headroom it needs.

### Measurement traps hit along the way

Recorded because each one produced a confident, wrong answer first:

- reading a probe's click count back over Accessibility is cached for about a
  second, which turns delivered clicks into "lost" ones. Writing the count
  straight to a file fixed it - but an *atomic* write per click stalls the
  probe's main thread for about as long, so the file has to be written through a
  handle opened once;
- synthetic clicks reach the target's handler about 1.5 s after being posted in
  this rig. That is the rig, not the utility: it is identical with the utility
  running and stopped (1544 ms versus 1544 ms). The real figure is the engine's
  own - 12 to 33 ms from mouse-down to the event being released;
- a window drifting on top of the probe makes every click look lost. The drivers
  now refuse to run unless the intended target really is the top-most ordinary
  window at the click point;
- the Handoff item in the Dock appears and disappears, which shifts every Dock
  icon. Dock coordinates have to be read live rather than hard-coded;
- `NSScreen.visibleFrame` read from a process that never initialised
  `NSApplication` reports the display's full height, which looked exactly like a
  stale cache in the utility. It was not.

## What was measured during development

These were run against real applications with synthetic clicks, using the
shipping engine. They are recorded here because several of them contradicted
reasonable-sounding assumptions.

| Check | Result |
|---|---|
| Plain `NSView` (does not accept first mouse) in an inactive window, 20 clicks, utility off | 0/20 clicks reached the view — the bug, reproduced |
| Same, utility on | 20/20 reached the view, exactly one mouse-down each |
| Background window of an inactive multi-window app | App activated, **the clicked window** became key, view received the click |
| IINA: one click on the OSC pause button of an inactive window | Activated and paused exactly once; playback clock frozen, verified via IINA's own clock |
| ⌘-click on an inactive window | Not activated; macOS's own click-through behaviour preserved |
| ⌃-click on an inactive window | Passed through unchanged |
| Event tap latency, warm | ~1 ms to decide; ~13 ms median for a click that activates another app |
| **Two displays, click a window on either monitor, 20 clicks each way** | **20/20 delivered.** Before the activation-wait fix: 17/20 and 16/20 |
| Busy 20-window app, clicking its background windows | No tap disables; worst callback ~274 ms, well inside the 1 s tap limit |

Three findings changed the implementation:

1. The Dock owns a transparent window spanning the whole display, and the mouse
   cursor is itself a window under the pointer. A naive topmost-window-under-
   cursor test returns one of those on **every** click, which would have made the
   utility a silent no-op.
2. On current macOS a standard `NSButton` already accepts the first click, as
   does IINA's pause button. The wasted first click is real for plain and custom
   views, not for stock controls — so the utility's value is narrower than the
   folklore suggests, and correctness around *not* misfiring matters more.
3. Requesting activation is not enough. `NSRunningApplication.activate()`
   returns immediately, and if the held mouse-down is released before the
   application has actually become active, AppKit still discards it as the
   activating click. With one display the race was almost always won, which is
   why it went unnoticed; with two displays it was lost about one click in five.
   The activation is now confirmed before the event is released, within a hard
   time budget.

An earlier experiment also confirmed that synthetic clicks are unnecessary:
swallowing the original event and re-posting it after activation worked, but so
did simply activating and returning the original event, which is strictly safer.

## Manual checklist

Put an inactive window on a second display, then click directly on a control.
Two displays are required for any of this: a click that stays on the display
that has focus is deliberately left to macOS.

Basic
- [ ] Click on an already-active window behaves normally
- [ ] Click on an inactive window **on another display** performs the action
      immediately
- [ ] Click on an inactive window on the display that already has focus behaves
      exactly as it does with the utility disabled - this is intended
- [ ] Displays with different resolutions / scale factors
- [ ] Displays arranged vertically and at odd offsets
- [ ] Toggling Enabled off restores stock macOS behaviour, on restores interception

Applications
- [ ] IINA: pause, play, timeline, volume, fullscreen
- [ ] Safari and Chrome: a button or link in an inactive window
- [ ] Finder: select an item in an inactive window
- [ ] Terminal, Xcode, a text editor: click into a text area
- [ ] System Settings: a control in an inactive window
- [ ] An Electron app

Must not misbehave
- [ ] Menu bar menus open and dismiss normally, on either display
- [ ] Dock clicks behave normally - ordinary, auto-hidden, and on the left or right edge
- [ ] Dock stacks: clicking a file in the fan selects it; dragging one out works
- [ ] A notification banner: clicking its close button dismisses it and does not
      bring the window behind it forward, including while focus is on another
      display
- [ ] The notification panel from the clock, and Control Center
- [ ] Context menus, sheets, dialogs, popovers
- [ ] Mission Control
- [ ] Clicking the wallpaper, then clicking a window again
- [ ] Dragging from an inactive window
- [ ] Right-click and ⌘-click on an inactive window
- [ ] Full-screen windows, including clicks along the top and bottom edges where
      the menu bar and Dock would otherwise be
- [ ] **No action ever happens twice from one click**

Lifecycle
- [ ] Survives sleep/wake
- [ ] Survives disconnecting and reconnecting a display
- [ ] Revoking Accessibility permission dims the icon; re-granting resumes within ~2 s
- [ ] Starts automatically after a reboot, already enabled

## Debug logging

Debug builds log the decision for every click (`ignore(reason)` or
`activate pid/window`):

```
./scripts/build-app.sh debug
log stream --predicate 'subsystem == "com.clickthrough.app"' --level debug
```

Release builds log only lifecycle events, and never log window titles or any
other user content.
