import Foundation
import LayoutSwitcherCore

enum ShortcutSettings {
    private static let key = "KeyboardShortcut"

    static func load(from defaults: UserDefaults = .standard) -> KeyboardShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
              shortcut.isValid else {
            return .defaultShortcut
        }
        return shortcut
    }

    @discardableResult
    static func save(_ shortcut: KeyboardShortcut, to defaults: UserDefaults = .standard) -> Bool {
        guard shortcut.isValid,
              let data = try? JSONEncoder().encode(shortcut) else {
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }
}
