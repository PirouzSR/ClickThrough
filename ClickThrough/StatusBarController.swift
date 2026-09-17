import AppKit

/// The only visible part of the application: one menu bar item with a two-item menu.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let controller: ClickThroughController
    private let accessibility: AccessibilityManager

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…",
                                               action: #selector(openAccessibilitySettings), keyEquivalent: "")

    init(controller: ClickThroughController, accessibility: AccessibilityManager) {
        self.controller = controller
        self.accessibility = accessibility
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        enabledItem.target = self
        accessibilityItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClickThrough", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        update()
    }

    /// Reflects the current state in the menu bar, using the standard macOS
    /// conventions: a slashed icon when switched off, a dimmed icon when the
    /// utility cannot work because Accessibility permission is missing.
    func update() {
        guard let button = statusItem.button else { return }
        let enabled = controller.isEnabled
        let active = controller.isActive

        let symbol = enabled ? "cursorarrow.click.2" : "cursorarrow.slash"
        let description = enabled
            ? (active ? "ClickThrough: enabled" : "ClickThrough: waiting for Accessibility permission")
            : "ClickThrough: disabled"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = enabled && !active

        enabledItem.state = enabled ? .on : .off
        // Only surfaced when it is actually needed, so the normal menu stays tiny.
        accessibilityItem.isHidden = accessibility.isTrusted
    }

    @objc private func toggleEnabled() {
        controller.setEnabled(!controller.isEnabled)
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityManager.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
