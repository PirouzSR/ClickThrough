import AppKit

// Explicit entry point. A nib-less AppKit application cannot use `@main` on the
// delegate: NSApplicationMain installs the delegate from the main nib, and with
// no nib the delegate would never be set and the app would launch doing nothing.
let application = NSApplication.shared
let delegate = AppDelegate()      // NSApplication.delegate is weak; hold it here
application.delegate = delegate
application.run()
