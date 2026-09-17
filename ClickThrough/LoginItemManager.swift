import Foundation
import ServiceManagement

/// Registers the app itself as a login item using the modern, supported API.
/// No helper application and no launchd plist are needed: `SMAppService.mainApp`
/// registers this bundle directly.
enum LoginItemManager {
    static func registerIfNeeded() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            break
        case .requiresApproval:
            // The user switched it off in System Settings > General > Login Items.
            // Respect that rather than re-registering behind their back.
            Log.app.info("Login item requires user approval; leaving as is")
        case .notRegistered, .notFound:
            do {
                try service.register()
                Log.app.info("Registered as login item")
            } catch {
                // Not fatal: the utility still runs, it just will not auto-start.
                Log.app.error("Could not register login item: \(error.localizedDescription, privacy: .public)")
            }
        @unknown default:
            break
        }
    }
}
