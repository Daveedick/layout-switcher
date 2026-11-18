import Foundation
import ServiceManagement

@MainActor
final class ServiceController {
    private let label = "local.layout-switcher.agent"
    private var service: SMAppService? {
        SMAppService.agent(plistName: "local.layout-switcher.agent.plist")
    }

    var status: SMAppService.Status { service?.status ?? .notFound }
    var isRegistered: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func enableAndHandOffCurrentProcess() throws {
        guard Bundle.main.bundleIdentifier == "local.layout-switcher.app" else {
            throw ServiceError.mustRunFromBundledApp
        }
        guard let service else { throw ServiceError.missingService }
        try service.register()
        if service.status == .requiresApproval { throw ServiceError.requiresApproval }
        // Ask launchd to own the app process before the current instance exits.
        let result = try kickstart()
        guard result == 0 else {
            try? service.unregister()
            throw ServiceError.launchFailed(result)
        }
    }

    func disable() throws {
        guard let service else { throw ServiceError.missingService }
        try service.unregister()
    }

    func kickstart() throws -> Int32 {
        try launchctl(["kickstart", "gui/\(getuid())/\(label)"])
    }

    private func launchctl(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private enum ServiceError: LocalizedError {
    case mustRunFromBundledApp, missingService, requiresApproval, launchFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .mustRunFromBundledApp: return "Запустите собранное Layout Switcher.app."
        case .missingService: return "В приложении не найден LaunchAgent."
        case .requiresApproval: return "Подтвердите автозапуск в Настройках системы → Основные → Объекты входа, затем перезапустите приложение."
        case .launchFailed(let code): return "launchd не запустил сервис (код \(code))."
        }
    }
}
