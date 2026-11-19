import AppKit
import Foundation
import Darwin
import ApplicationServices
import CoreGraphics
import LayoutSwitcherCore

private let showSetupNotification = Notification.Name("local.layout-switcher.show-setup")

@main
enum LayoutSwitcherEntry {
    private static var lockFD: Int32 = -1
    static func main() {
        let args = Set(CommandLine.arguments.dropFirst())
        if args.contains("--watchdog") { Watchdog.run() }
        // Old registrations may still point here until the user enables the new watchdog.
        if args.contains("--managed") { return }
        if args.contains("--version") {
            print("Layout Switcher \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
            return
        }
        if args.contains("--self-check") {
            let sources = InputSources.availabilityReport()
            let allAvailable = sources.allSatisfy { $0.contains(": available") }
            let info = Bundle.main.infoDictionary ?? [:]
            print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
            print("App path: \(Bundle.main.bundleURL.path)")
            print("Version: \(info["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(info["CFBundleVersion"] as? String ?? "unknown"))")
            print("Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "no")")
            print("Input Monitoring granted: \(CGPreflightListenEventAccess() ? "yes" : "no")")
            sources.forEach { print($0) }
            if !allAvailable { exit(1) }
            return
        }
        if args.contains("--shortcut-settings-preview") {
            let suiteName = "local.layout-switcher.shortcut-preview.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { exit(1) }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = AppDelegate(settingsPreviewDefaults: defaults, previewSuiteName: suiteName)
            app.delegate = delegate
            app.run()
            _ = delegate
            return
        }
        let lockPath = NSTemporaryDirectory() + "local.layout-switcher.app.lock"
        lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { exit(75) }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            // A second launch asks the already-running instance to show its setup UI.
            DistributedNotificationCenter.default().postNotificationName(
                showSetupNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
            exit(0)
        }
        Watchdog.prepareGUI()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settingsPreview: Bool
    private let settingsDefaults: UserDefaults
    private let previewSuiteName: String?
    private var statusItem: NSStatusItem!
    private var menuBarIcon: NSImage?
    private var runtime: SwitcherRuntime!
    private var currentShortcut = KeyboardShortcut.defaultShortcut
    private var serviceProvider: LayoutSwitcherServiceProvider?
    private var service: ServiceController!
    private var serviceError: String?
    private var statusText = "Запуск…"
    private var setupWindow: NSWindow?
    private var setupStatusLabel: NSTextField?
    private var setupUsageLabel: NSTextField?
    private var setupNotificationToken: NSObjectProtocol?
    private var shortcutSettingsWindow: ShortcutSettingsWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var darkDockIcon = Bundle.main.image(forResource: NSImage.Name("AppIconDark"))

    init(settingsPreviewDefaults: UserDefaults? = nil, previewSuiteName: String? = nil) {
        settingsPreview = settingsPreviewDefaults != nil
        settingsDefaults = settingsPreviewDefaults ?? .standard
        self.previewSuiteName = previewSuiteName
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateDockIcon() }
        }
        currentShortcut = ShortcutSettings.load(from: settingsDefaults)
        if settingsPreview {
            showShortcutSettings()
            return
        }

        service = ServiceController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarIcon = Self.loadMenuBarIcon()
        statusItem.button?.image = menuBarIcon
        statusItem.button?.imagePosition = .imageOnly
        runtime = SwitcherRuntime(shortcut: currentShortcut, onStatus: { [weak self] status in
            Task { @MainActor in self?.statusText = Self.localizedStatus(status); self?.refreshMenu() }
        })
        serviceProvider = LayoutSwitcherServiceProvider { [weak runtime = self.runtime] text in
            runtime?.convertServiceText(text)
        }
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        runtime.start()
        refreshMenu()
        setupNotificationToken = DistributedNotificationCenter.default().addObserver(
            forName: showSetupNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSetupWindow() }
        }
        if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            showSetupWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsPreview { return false }
        showSetupWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutSettingsWindow?.stopForTermination()
        if settingsPreview, let previewSuiteName {
            settingsDefaults.removePersistentDomain(forName: previewSuiteName)
        } else {
            ClipboardReplacement.flushIfOwned()
            if service?.isRegistered == true { Watchdog.markCleanExit() }
        }
        if let setupNotificationToken {
            DistributedNotificationCenter.default().removeObserver(setupNotificationToken)
            self.setupNotificationToken = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { settingsPreview }

    func applicationDidHide(_ notification: Notification) {
        updateWindowActivationPolicy()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateWindowActivationPolicy()
    }

    private static func localizedStatus(_ status: String) -> String {
        switch status {
        case "Stopped": return "Остановлен"
        case "Paused": return "Приостановлен"
        case "Running": return "Активен"
        case "Accessibility permission required": return "Нет разрешения Универсального доступа"
        case "Input Monitoring permission required": return "Нет разрешения Мониторинга ввода"
        case "Grant Accessibility and Input Monitoring, then retry": return "Разрешите доступ в настройках и повторите"
        case "Keyboard monitor recovered": return "Монитор клавиатуры восстановлен"
        case "Converted": return "Текст переключён"
        case "Text converted; target input source could not be selected": return "Текст изменён, раскладка не выбрана"
        default: return status
        }
    }

    private func refreshMenu() {
        let accessibilityDescription = "Layout Switcher — \(statusText)"
        statusItem.button?.toolTip = accessibilityDescription
        statusItem.button?.setAccessibilityLabel(accessibilityDescription)
        statusItem.button?.alphaValue = runtime.isKeyboardMonitorAvailable ? 1 : 0.45
        setupStatusLabel?.stringValue = statusText
        let menu = NSMenu()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if runtime.isSecureInputPaused {
            let copy = NSMenuItem(title: "Исправить текст в буфере обмена", action: #selector(convertCopiedText),
                                  keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: runtime.isRunning ? "Приостановить" : "Возобновить", action: #selector(toggleRuntime), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let retry = NSMenuItem(title: "Повторить запрос разрешений", action: #selector(retryPermissions), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        let shortcut = NSMenuItem(title: "Сочетание клавиш: \(Self.shortcutName(currentShortcut))…",
                                  action: #selector(showShortcutSettingsAction), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)
        let accessibility = NSMenuItem(title: "Открыть настройки Универсального доступа", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        let inputMonitoring = NSMenuItem(title: "Открыть настройки Мониторинга ввода", action: #selector(openInputMonitoring), keyEquivalent: "")
        inputMonitoring.target = self
        menu.addItem(inputMonitoring)
        let setup = NSMenuItem(title: "Состояние и разрешения…", action: #selector(showSetupWindowAction), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let loginTitle: String
        if service.isRegistered {
            loginTitle = "Отключить автозапуск и восстановление"
        } else if service.requiresApproval {
            loginTitle = "Открыть настройки объектов входа…"
        } else {
            loginTitle = "Включить вход и восстановление после сбоя…"
        }
        if service.requiresApproval {
            let approval = NSMenuItem(title: "Автозапуск ожидает подтверждения в Настройках системы", action: nil, keyEquivalent: "")
            approval.isEnabled = false
            menu.addItem(approval)
        }
        let login = NSMenuItem(title: loginTitle, action: #selector(toggleService), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        if let serviceError {
            let error = NSMenuItem(title: serviceError, action: nil, keyEquivalent: "")
            error.isEnabled = false
            menu.addItem(error)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private static func loadMenuBarIcon() -> NSImage? {
        let image = Bundle.main.image(forResource: NSImage.Name("MenuIcon"))
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Layout Switcher")
        image?.size = NSSize(width: 32, height: 18)
        image?.isTemplate = true
        return image
    }

    @objc private func toggleRuntime() {
        runtime.isRunning ? runtime.stop() : runtime.start()
        refreshMenu()
    }

    @objc private func convertCopiedText() {
        if !ClipboardReplacement.transformCopiedText(on: .general, transform: { LayoutConverter.convert($0)?.text }) {
            NSSound.beep()
        }
    }

    @objc private func retryPermissions() {
        runtime.retryPermissions()
        refreshMenu()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func showSetupWindowAction() { showSetupWindow() }

    @objc private func showShortcutSettingsAction() { showShortcutSettings() }

    private func showShortcutSettings() {
        if shortcutSettingsWindow == nil {
            shortcutSettingsWindow = ShortcutSettingsWindow(
                shortcut: currentShortcut,
                defaults: settingsDefaults,
                onShortcutChanged: { [weak self] shortcut in self?.shortcutDidChange(shortcut) },
                onRecordingChanged: { [weak self] recording in self?.runtime?.setShortcutRecording(recording) },
                onWindowClosed: { [weak self] in self?.updateActivationPolicyAfterClose() }
            )
        }
        presentWindow { shortcutSettingsWindow?.show() }
    }

    private func shortcutDidChange(_ shortcut: KeyboardShortcut) {
        guard shortcut.isValid else { return }
        currentShortcut = shortcut
        runtime?.updateShortcut(shortcut)
        setupUsageLabel?.stringValue = Self.usageDescription(for: currentShortcut)
        if !settingsPreview { refreshMenu() }
    }

    private func showSetupWindow() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Layout Switcher — состояние и разрешения"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()

            let heading = NSTextField(labelWithString: "Состояние")
            heading.font = .boldSystemFont(ofSize: 16)
            let state = NSTextField(wrappingLabelWithString: statusText)
            state.maximumNumberOfLines = 2
            setupStatusLabel = state

            let usage = NSTextField(wrappingLabelWithString: Self.usageDescription(for: currentShortcut))
            usage.maximumNumberOfLines = 3
            setupUsageLabel = usage
            let punto = NSTextField(wrappingLabelWithString: "Перед проверкой отключите Punto Switcher, чтобы горячие клавиши не конфликтовали.")
            punto.maximumNumberOfLines = 2

            let accessibility = NSButton(title: "Универсальный доступ", target: self, action: #selector(openAccessibility))
            let inputMonitoring = NSButton(title: "Мониторинг ввода", target: self, action: #selector(openInputMonitoring))
            let check = NSButton(title: "Проверить разрешения", target: self, action: #selector(retryPermissions))
            let hide = NSButton(title: "Скрыть", target: self, action: #selector(hideSetupWindow))
            let permissionButtons = NSStackView(views: [accessibility, inputMonitoring])
            permissionButtons.orientation = .horizontal
            permissionButtons.distribution = .fillEqually
            permissionButtons.spacing = 10
            let actionButtons = NSStackView(views: [check, hide])
            actionButtons.orientation = .horizontal
            actionButtons.distribution = .fillEqually
            actionButtons.spacing = 10

            let stack = NSStackView(views: [heading, state, usage, punto, permissionButtons, actionButtons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView = NSView()
            window.contentView?.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -22),
            ])
            for view in [state, usage, punto, permissionButtons, actionButtons] as [NSView] {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            setupWindow = window
        }
        presentWindow { setupWindow?.makeKeyAndOrderFront(nil) }
    }

    @objc private func hideSetupWindow() {
        setupWindow?.orderOut(nil)
        updateWindowActivationPolicy()
    }

    func windowWillClose(_ notification: Notification) {
        updateActivationPolicyAfterClose()
    }

    private func updateActivationPolicyAfterClose() {
        // Read visibility after AppKit finishes closing the window.
        Task { @MainActor [weak self] in self?.updateWindowActivationPolicy() }
    }

    private func presentWindow(_ show: () -> Void) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        NSApp.setActivationPolicy(.regular)
        updateDockIcon()
        show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateWindowActivationPolicy() {
        let hasVisibleWindow = setupWindow?.isVisible == true || shortcutSettingsWindow?.isVisible == true
        let policy: NSApplication.ActivationPolicy = hasVisibleWindow && !NSApp.isHidden ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            updateDockIcon()
        }
    }

    private func updateDockIcon() {
        guard NSApp.activationPolicy() == .regular else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? darkDockIcon : nil
    }

    private static func usageDescription(for shortcut: KeyboardShortcut) -> String {
        "\(shortcutName(shortcut)) переключает выделенный текст; если выделения нет, используется последнее набранное слово."
    }

    private static func shortcutName(_ shortcut: KeyboardShortcut) -> String {
        ShortcutSettingsWindow.displayName(for: shortcut)
    }

    @objc private func toggleService() {
        if service.requiresApproval {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        serviceError = nil
        do {
            if service.isRegistered {
                try service.disable()
            } else {
                try service.enable()
            }
        } catch {
            serviceError = "Автозапуск: \(error.localizedDescription)"
        }
        refreshMenu()
    }

    @objc private func quit() {
        runtime.stop()
        NSApp.terminate(nil)
    }
}
