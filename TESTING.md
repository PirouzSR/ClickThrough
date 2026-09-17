# Testing

## Automated

`ClickThroughTests/WindowFinderTests.swift` covers the click policy, which is a
pure function and therefore testable without a window server. 19 tests:
active vs inactive windows, background windows of the active and of an inactive
application, negative-coordinate secondary displays, the menu bar and Dock
strips, open menus, floating panels, the Dock backdrop and cursor overlay,
fully transparent windows, desktop windows, own windows, modifiers, and the
AppKit→CoreGraphics coordinate flip.

```
xcodebuild -project ClickThrough.xcodeproj -scheme ClickThrough test
```

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
| Event tap latency, warm | ~1 ms (window list ~2 ms median; first call ~50 ms, so it is warmed up at launch) |

Two findings changed the implementation:

1. The Dock owns a transparent window spanning the whole display, and the mouse
   cursor is itself a window under the pointer. A naive topmost-window-under-
   cursor test returns one of those on **every** click, which would have made the
   utility a silent no-op.
2. On current macOS a standard `NSButton` already accepts the first click, as
   does IINA's pause button. The wasted first click is real for plain and custom
   views, not for stock controls — so the utility's value is narrower than the
   folklore suggests, and correctness around *not* misfiring matters more.

An earlier experiment also confirmed that synthetic clicks are unnecessary:
swallowing the original event and re-posting it after activation worked, but so
did simply activating and returning the original event, which is strictly safer.

## Manual checklist

Put an inactive window on a second display, then click directly on a control.

Basic
- [ ] Click on an already-active window behaves normally
- [ ] Click on an inactive window performs the action immediately
- [ ] Same, with the inactive window on another display
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
- [ ] Menu bar menus open and dismiss normally
- [ ] Dock clicks behave normally
- [ ] Context menus, sheets, dialogs, popovers
- [ ] Mission Control and Launchpad
- [ ] Dragging from an inactive window
- [ ] Right-click and ⌘-click on an inactive window
- [ ] Fullscreen applications
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
