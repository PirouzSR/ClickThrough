import AppKit
import ApplicationServices

/// Tracks the Accessibility (AXIsProcessTrusted) permission.
///
/// The permission experience is deliberately the system's own: macOS shows its
/// standard prompt once, and after that the utility simply waits. It never nags,
/// never shows an alert of its own and never blocks anything behind onboarding.
@MainActor
final class AccessibilityManager {
    /// Called when trust is granted or revoked.
    var onTrustChanged: (() -> Void)?

    /// Only ever touched on the main actor; `nonisolated(unsafe)` lets `deinit`
    /// invalidate it so the run loop cannot keep a dead object's timer alive.
    private nonisolated(unsafe) var timer: Timer?
    private var lastKnownTrust: Bool

    /// Poll quickly while waiting for the user to grant permission in System
    /// Settings, slowly afterwards just to notice revocation.
    private static let untrustedPollInterval: TimeInterval = 2
    private static let trustedPollInterval: TimeInterval = 15

    /// `kAXTrustedCheckOptionPrompt` is imported as a mutable global, which
    /// strict concurrency checking rejects; its documented value is used instead.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    var isTrusted: Bool { AXIsProcessTrusted() }

    init() {
        lastKnownTrust = AXIsProcessTrusted()
    }

    deinit { timer?.invalidate() }

    /// Triggers the standard macOS permission prompt, once, and only when the
    /// permission is actually missing.
    func promptIfNeeded() {
        guard !isTrusted else { return }
        _ = AXIsProcessTrustedWithOptions([Self.promptOptionKey: true] as CFDictionary)
    }

    func startMonitoring() {
        scheduleTimer(interval: lastKnownTrust ? Self.trustedPollInterval : Self.untrustedPollInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.checkTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastKnownTrust else { return }
        lastKnownTrust = trusted
        Log.app.info("Accessibility trust changed: \(trusted, privacy: .public)")
        scheduleTimer(interval: trusted ? Self.trustedPollInterval : Self.untrustedPollInterval)
        onTrustChanged?()
    }

    /// Opens System Settings directly at Privacy & Security -> Accessibility.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
