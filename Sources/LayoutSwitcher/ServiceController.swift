import Foundation
import ServiceManagement

@MainActor
final class ServiceController {
    private let service = SMAppService.agent(plistName: "local.layout-switcher.watchdog.plist")

    var isRegistered: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    func enable() throws {
        let legacy = SMAppService.agent(plistName: "local.layout-switcher.agent.plist")
        if legacy.status == .enabled || legacy.status == .requiresApproval {
            do {
                try legacy.unregister()
            } catch where legacy.status == .notRegistered || legacy.status == .notFound {
                // The old job may already have been removed from launchd.
            }
        }
        try service.register()
    }

    func disable() throws {
        try service.unregister()
    }
}
