import AppKit
import LayoutSwitcherCore

@MainActor
final class ShortcutSettingsWindow: NSObject, NSWindowDelegate {
    private static let functionKeyCodes: Set<UInt16> = [64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122]
    private static let navigationKeyCodes: Set<UInt16> = [115, 116, 117, 119, 121, 123, 124, 125, 126]
    private let defaults: UserDefaults
    private let onShortcutChanged: (KeyboardShortcut) -> Void
    private let onRecordingChanged: (Bool) -> Void
    private let onWindowClosed: () -> Void

    private let window: NSWindow
    private let shortcutLabel: NSTextField
    private let messageLabel: NSTextField
    private let recordButton: NSButton
    private var shortcut: KeyboardShortcut
    private var localMonitor: Any?
    private var modifierOnlyCandidate: ShortcutModifiers = []
    private var capturedKeyCode: UInt16?
    private var capturedKeyModifiers: ShortcutModifiers = []
    private var capturedKeyReleased = false
    private var isRecording = false
    private var hasPresented = false

    var isVisible: Bool { window.isVisible }

    init(shortcut: KeyboardShortcut,
         defaults: UserDefaults = .standard,
         onShortcutChanged: @escaping (KeyboardShortcut) -> Void,
         onRecordingChanged: @escaping (Bool) -> Void,
         onWindowClosed: @escaping () -> Void) {
        self.shortcut = shortcut
        self.defaults = defaults
        self.onShortcutChanged = onShortcutChanged
        self.onRecordingChanged = onRecordingChanged
        self.onWindowClosed = onWindowClosed

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 214),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Сочетание клавиш"
        window.isReleasedWhenClosed = false
        shortcutLabel = NSTextField(labelWithString: Self.displayName(for: shortcut))
        messageLabel = NSTextField(wrappingLabelWithString: "")
        recordButton = NSButton(title: "Записать…", target: nil, action: nil)

        super.init()
        buildWindow()
        window.delegate = self
    }

    func show() {
        if !hasPresented {
            window.center()
            hasPresented = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isRecording else { return }
        stopRecording(message: "Запись отменена: окно потеряло фокус.")
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(message: "Запись отменена.")
        onWindowClosed()
    }

    func stopForTermination() {
        stopRecording(message: nil)
    }

    private func buildWindow() {
        shortcutLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        shortcutLabel.alignment = .center
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.setAccessibilityLabel("Текущее сочетание: \(Self.displayName(for: shortcut))")

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2

        let explanation = NSTextField(wrappingLabelWithString:
            "Запишите два или более модификатора либо сочетание с ⌃, ⌥ или ⌘. Настройка применяется после отпускания клавиш.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .center
        explanation.maximumNumberOfLines = 2

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.setAccessibilityLabel("Записать сочетание клавиш")
        let resetButton = NSButton(title: "По умолчанию", target: self, action: #selector(resetShortcut))
        resetButton.setAccessibilityLabel("Вернуть сочетание по умолчанию")

        let buttons = NSStackView(views: [recordButton, resetButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        let stack = NSStackView(views: [shortcutLabel, messageLabel, explanation, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 250),
        ])
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording(message: "Запись отменена.")
        } else {
            beginRecording()
        }
    }

    @objc private func resetShortcut() {
        guard !isRecording else { return }
        commit(.defaultShortcut)
    }

    private func beginRecording() {
        resetCandidate()
        isRecording = true
        messageLabel.stringValue = "Нажмите сочетание. Esc отменяет запись."
        recordButton.title = "Отменить"
        onRecordingChanged(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.isRecording, self.window.isKeyWindow else {
                if self.isRecording { self.stopRecording(message: "Запись отменена: окно потеряло фокус.") }
                return event
            }
            return self.handleRecordedEvent(event)
        }
        if localMonitor == nil {
            stopRecording(message: "Не удалось начать запись сочетания.")
        }
    }

    private func handleRecordedEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            stopRecording(message: "Запись отменена.")
            return nil
        }
        if event.type == .flagsChanged, event.keyCode == 57 {
            stopRecording(message: "Caps Lock нельзя использовать как модификатор.")
            return nil
        }
        if hasUnsupportedModifier(event.modifierFlags, keyCode: event.keyCode, isFlagsChange: event.type == .flagsChanged) {
            stopRecording(message: "Fn и Help не поддерживаются.")
            return nil
        }
        if event.keyCode == 114 {
            stopRecording(message: "Клавиша Help не поддерживается.")
            return nil
        }

        switch event.type {
        case .flagsChanged:
            handleModifierChange(modifiers(from: event.modifierFlags))
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        default:
            break
        }
        return nil
    }

    private func handleModifierChange(_ current: ShortcutModifiers) {
        if let _ = capturedKeyCode {
            guard isSubset(current, of: capturedKeyModifiers) else {
                stopRecording(message: "Во время записи нельзя добавлять другие модификаторы.")
                return
            }
            if capturedKeyReleased && current.isEmpty { finishCapturedKey() }
            return
        }

        if current.isEmpty {
            guard !modifierOnlyCandidate.isEmpty else { return }
            commit(KeyboardShortcut(modifiers: modifierOnlyCandidate, keyCode: nil))
            return
        }

        if modifierOnlyCandidate.isEmpty {
            modifierOnlyCandidate = current
        } else if isSubset(modifierOnlyCandidate, of: current) {
            modifierOnlyCandidate = current
        } else if !isSubset(current, of: modifierOnlyCandidate) {
            stopRecording(message: "Отпустите одну комбинацию целиком и начните запись заново.")
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard capturedKeyCode == nil else {
            stopRecording(message: "Дополнительные клавиши не поддерживаются. Запишите сочетание снова.")
            return
        }
        let current = modifiers(from: event.modifierFlags)
        guard current.contains(.command) || current.contains(.control) || current.contains(.option) else {
            stopRecording(message: "Добавьте ⌃, ⌥ или ⌘ вместе с клавишей.")
            return
        }
        if !modifierOnlyCandidate.isEmpty && !isSubset(modifierOnlyCandidate, of: current) {
            stopRecording(message: "Модификаторы изменились во время записи. Начните заново.")
            return
        }
        capturedKeyCode = event.keyCode
        capturedKeyModifiers = current
        capturedKeyReleased = false
        modifierOnlyCandidate = []
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard let capturedKeyCode else { return }
        guard event.keyCode == capturedKeyCode else {
            stopRecording(message: "Дополнительные клавиши не поддерживаются. Запишите сочетание снова.")
            return
        }
        capturedKeyReleased = true
        let current = modifiers(from: event.modifierFlags)
        guard isSubset(current, of: capturedKeyModifiers) else {
            stopRecording(message: "Модификаторы изменились до отпускания сочетания. Запишите его снова.")
            return
        }
        if current.isEmpty { finishCapturedKey() }
    }

    private func finishCapturedKey() {
        guard let keyCode = capturedKeyCode else { return }
        commit(KeyboardShortcut(modifiers: capturedKeyModifiers, keyCode: keyCode))
    }

    private func commit(_ candidate: KeyboardShortcut) {
        guard candidate.isValid, ShortcutSettings.save(candidate, to: defaults) else {
            stopRecording(message: "Это сочетание не поддерживается.")
            return
        }
        shortcut = candidate
        updateShortcutDisplay()
        stopRecording(message: "Сочетание сохранено.")
        onShortcutChanged(candidate)
    }

    private func stopRecording(message: String?) {
        guard isRecording else {
            if let message { messageLabel.stringValue = message }
            return
        }
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        resetCandidate()
        recordButton.title = "Записать…"
        if let message { messageLabel.stringValue = message }
        onRecordingChanged(false)
    }

    private func resetCandidate() {
        modifierOnlyCandidate = []
        capturedKeyCode = nil
        capturedKeyModifiers = []
        capturedKeyReleased = false
    }

    private func updateShortcutDisplay() {
        let title = Self.displayName(for: shortcut)
        shortcutLabel.stringValue = title
        shortcutLabel.setAccessibilityLabel("Текущее сочетание: \(title)")
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func hasUnsupportedModifier(_ flags: NSEvent.ModifierFlags,
                                        keyCode: UInt16,
                                        isFlagsChange: Bool) -> Bool {
        let functionModifierBelongsToKey = !isFlagsChange &&
            (Self.functionKeyCodes.contains(keyCode) || Self.navigationKeyCodes.contains(keyCode))
        return flags.contains(.help) || (flags.contains(.function) && !functionModifierBelongsToKey)
    }

    private func isSubset(_ candidate: ShortcutModifiers, of other: ShortcutModifiers) -> Bool {
        candidate.intersection(other) == candidate
    }

    static func displayName(for shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("⌃") }
        if shortcut.modifiers.contains(.option) { parts.append("⌥") }
        if shortcut.modifiers.contains(.shift) { parts.append("⇧") }
        if shortcut.modifiers.contains(.command) { parts.append("⌘") }
        if let keyCode = shortcut.keyCode { parts.append(keyName(for: keyCode)) }
        return parts.joined(separator: " ")
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let labels: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
            65: "Цифр. .", 67: "Цифр. *", 69: "Цифр. +", 71: "Цифр. Clear", 75: "Цифр. /",
            76: "Цифр. Enter", 78: "Цифр. -", 81: "Цифр. =", 82: "Цифр. 0", 83: "Цифр. 1",
            84: "Цифр. 2", 85: "Цифр. 3", 86: "Цифр. 4", 87: "Цифр. 5", 88: "Цифр. 6",
            89: "Цифр. 7", 91: "Цифр. 8", 92: "Цифр. 9", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            64: "F17", 79: "F18", 80: "F19", 90: "F20",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            118: "F4", 120: "F2", 122: "F1"
        ]
        return labels[keyCode] ?? "Клавиша \(keyCode)"
    }

}
