import AppKit
import CoreGraphics

/// A left-button event tap running on its own thread.
///
/// Invariant: this tap **never** swallows, rewrites or synthesises an event. It
/// only ever delays a mouse-down by the microseconds it takes to activate the
/// application underneath, then returns the user's original event. That is what
/// guarantees one physical click can never become two logical clicks.
final class EventTap: @unchecked Sendable {
    /// Called on the tap thread for each left mouse-down, before the event is released.
    private let onMouseDown: (CGEvent) -> Void

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    private(set) var isRunning = false

    init(onMouseDown: @escaping (CGEvent) -> Void) {
        self.onMouseDown = onMouseDown
    }

    deinit { stop() }

    /// Left-button events only.
    ///
    /// Mouse-up and mouse-dragged are in the mask purely to preserve ordering:
    /// events outside the mask bypass the tap entirely, so a fast click's
    /// mouse-up could otherwise overtake a mouse-down we are briefly holding.
    /// Both are returned untouched.
    private static let eventMask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue)

    /// Creates the tap and starts its thread. Returns false when the system
    /// refuses, which in practice means Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        // An active (non-listen-only) tap is required: the window server waits for
        // the callback to return before routing the event, which is precisely the
        // window in which the target application is activated.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: Self.eventMask,
                                           callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.app.notice("Event tap could not be created (Accessibility permission missing?)")
            return false
        }

        machPort = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        isRunning = true

        // The tap runs on a dedicated high-priority thread so that AppKit work on
        // the main thread can never add latency to the user's mouse, and so that
        // the brief activation wait never blocks the UI.
        let thread = Thread { [weak self] in
            // Read the CoreFoundation handles from `self` rather than capturing
            // them: they are not Sendable, and this closure is @Sendable.
            guard let self, let port = self.machPort, let source = self.runLoopSource else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            Log.app.info("Event tap running")
            CFRunLoopRun()
            Log.app.info("Event tap thread finished")
        }
        thread.name = "com.clickthrough.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop = threadRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        machPort = nil
        runLoopSource = nil
        threadRunLoop = nil
        thread = nil
        Log.app.info("Event tap stopped")
    }

    /// The system disables taps that time out; also re-arm after wake, when the
    /// tap can come back disabled.
    func reenableIfNeeded() {
        guard isRunning, let port = machPort else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            Log.app.notice("Event tap was disabled; re-enabling")
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-arm immediately: without this the utility would silently stop
            // working for the rest of the session.
            if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
            Log.app.notice("Event tap disabled by system (\(type.rawValue)); re-enabled")
        case .leftMouseDown:
            onMouseDown(event)
        default:
            break   // mouse-up / dragged: present only to keep ordering
        }
        return Unmanaged.passUnretained(event)
    }
}

/// C callback trampoline: event taps take a plain function pointer, so the tap
/// instance is passed through `userInfo`.
private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
