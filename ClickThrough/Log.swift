import Foundation
import os

/// Logging is deliberately quiet in release builds: the utility is invisible by
/// design, and the hot path must not pay for string interpolation on every click.
enum Log {
    private static let subsystem = "com.clickthrough.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tap = Logger(subsystem: subsystem, category: "tap")

    /// Verbose per-click tracing. Compiled out of release builds entirely.
    @inline(__always)
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Evaluated into a local first: os_log's interpolation is @escaping, and
        // an @autoclosure parameter cannot be captured by an escaping closure.
        let text = message()
        tap.debug("\(text, privacy: .public)")
        #endif
    }
}
