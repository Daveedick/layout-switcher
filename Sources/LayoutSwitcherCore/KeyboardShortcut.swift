public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let all: Self = [.control, .option, .shift, .command]
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public let modifiers: ShortcutModifiers
    public let keyCode: UInt16?

    public init(modifiers: ShortcutModifiers, keyCode: UInt16?) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    public static let defaultShortcut = Self(modifiers: [.option, .command], keyCode: nil)

    public var isValid: Bool {
        guard modifiers.rawValue & ~ShortcutModifiers.all.rawValue == 0 else { return false }
        let count = modifiers.rawValue.nonzeroBitCount
        guard let keyCode else { return count >= 2 }
        let excludedKeyCodes: Set<UInt16> = [53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        let hasCommandControlOrOption = !modifiers.intersection([.command, .control, .option]).isEmpty
        return keyCode <= 127 && !excludedKeyCodes.contains(keyCode)
            && hasCommandControlOrOption
    }

    private enum CodingKeys: String, CodingKey { case modifiers, keyCode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container,
                                                   debugDescription: "Invalid keyboard shortcut")
        }
    }
}

public enum ShortcutRecognitionResult: Equatable, Sendable {
    case passThrough
    case consume
    case trigger
}

/// Pure recognizer for one configured shortcut. Call every method from one serialized event source.
public struct ShortcutRecognizer: Sendable {
    private var shortcut: KeyboardShortcut
    private var currentModifiers: ShortcutModifiers = []
    private var active = false
    private var cancelled = false
    private var exactModifiersWereDown = false
    private var matchedKeyWasPressed = false
    private var matchedKeyWasReleased = false
    private var ownedKeyCode: UInt16?
    private var ordinaryKeysDown = Set<UInt16>()
    private var requiresNeutralState = false

    public init(shortcut: KeyboardShortcut = .defaultShortcut) {
        self.shortcut = shortcut.isValid ? shortcut : .defaultShortcut
    }

    public var configuration: KeyboardShortcut { shortcut }
    public func ownsKeyUp(for keyCode: UInt16) -> Bool { ownedKeyCode == keyCode }

    /// Update configuration while retaining ownership of an already swallowed key-up.
    public mutating func updateShortcut(_ shortcut: KeyboardShortcut) {
        guard shortcut.isValid else { return }
        self.shortcut = shortcut
        cancelGesture()
    }

    /// Cancel a candidate without losing the matching key-up that completes a swallowed key-down.
    public mutating func cancelGesture() {
        requiresNeutralState = requiresNeutralState || !currentModifiers.isEmpty
            || !ordinaryKeysDown.isEmpty || ownedKeyCode != nil
        active = false
        cancelled = false
        exactModifiersWereDown = false
        matchedKeyWasPressed = false
        matchedKeyWasReleased = false
    }

    /// Reset after the event tap is stopped or disabled and can no longer own a paired key-up.
    public mutating func reset() {
        cancelGesture()
        ownedKeyCode = nil
        currentModifiers = []
        ordinaryKeysDown.removeAll(keepingCapacity: true)
        requiresNeutralState = false
    }

    /// Track physical state while a settings recorder owns the input, without matching shortcuts.
    public mutating func observeModifiersWhileRecording(_ modifiers: ShortcutModifiers) {
        currentModifiers = modifiers.intersection(.all)
        clearNeutralLatchIfReady()
    }

    public mutating func observeKeyDownWhileRecording(_ keyCode: UInt16, modifiers: ShortcutModifiers) {
        currentModifiers = modifiers.intersection(.all)
        if ownedKeyCode != keyCode { ordinaryKeysDown.insert(keyCode) }
    }

    /// Returns true only for a key-up paired with a key-down this recognizer consumed.
    public mutating func observeKeyUpWhileRecording(_ keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool {
        currentModifiers = modifiers.intersection(.all)
        if ownedKeyCode == keyCode {
            ownedKeyCode = nil
            matchedKeyWasReleased = matchedKeyWasPressed
            clearNeutralLatchIfReady()
            return true
        }
        ordinaryKeysDown.remove(keyCode)
        clearNeutralLatchIfReady()
        return false
    }

    public mutating func modifiersChanged(_ modifiers: ShortcutModifiers,
                                          hasUnsupportedModifier: Bool = false) -> ShortcutRecognitionResult {
        currentModifiers = modifiers.intersection(.all)
        if requiresNeutralState {
            clearNeutralLatchIfReady()
            return .passThrough
        }
        if !active,
           !currentModifiers.intersection(shortcut.modifiers).isEmpty {
            beginCandidate()
        }
        // Latch cancellation once a candidate has begun, even if an unsupported modifier
        // (notably physical Fn) arrives before the configured modifiers are all down.
        if hasUnsupportedModifier || hasExtraModifiers(currentModifiers) { cancelActiveCandidate() }

        guard active else { return .passThrough }
        if !cancelled, currentModifiers == shortcut.modifiers { exactModifiersWereDown = true }

        guard currentModifiers.isEmpty else { return .passThrough }
        if shortcut.keyCode == nil {
            let shouldTrigger = exactModifiersWereDown && !cancelled
            clearCandidate()
            return shouldTrigger ? .trigger : .passThrough
        }
        if matchedKeyWasPressed && matchedKeyWasReleased {
            let shouldTrigger = exactModifiersWereDown && !cancelled
            clearCandidate()
            return shouldTrigger ? .trigger : .passThrough
        }
        if !matchedKeyWasPressed && ownedKeyCode == nil { clearCandidate() }
        return .passThrough
    }

    public mutating func keyDown(keyCode: UInt16,
                                 modifiers: ShortcutModifiers,
                                 hasUnsupportedModifier: Bool = false,
                                 isRepeat: Bool = false) -> ShortcutRecognitionResult {
        currentModifiers = modifiers.intersection(.all)
        if ownedKeyCode == keyCode {
            if hasUnsupportedModifier || hasExtraModifiers(currentModifiers) { cancelActiveCandidate() }
            return .consume
        }
        if requiresNeutralState {
            if !isRepeat { ordinaryKeysDown.insert(keyCode) }
            return .passThrough
        }

        if hasUnsupportedModifier || hasExtraModifiers(currentModifiers) { cancelActiveCandidate() }
        if !active, !currentModifiers.intersection(shortcut.modifiers).isEmpty { beginCandidate() }

        let matchesKeyCombo = shortcut.keyCode == keyCode
            && currentModifiers == shortcut.modifiers
            && !hasUnsupportedModifier
            && ordinaryKeysDown.isEmpty
        if matchesKeyCombo, active, !cancelled, !matchedKeyWasPressed, ownedKeyCode == nil {
            exactModifiersWereDown = true
            matchedKeyWasPressed = true
            ownedKeyCode = keyCode
            return .consume
        }

        if active { cancelled = true }
        if !isRepeat { ordinaryKeysDown.insert(keyCode) }
        return .passThrough
    }

    public mutating func keyUp(keyCode: UInt16,
                               modifiers: ShortcutModifiers,
                               hasUnsupportedModifier: Bool = false) -> ShortcutRecognitionResult {
        currentModifiers = modifiers.intersection(.all)
        if ownedKeyCode == keyCode {
            ownedKeyCode = nil
            if hasUnsupportedModifier || hasExtraModifiers(currentModifiers) { cancelActiveCandidate() }
            matchedKeyWasReleased = matchedKeyWasPressed
            if requiresNeutralState {
                clearNeutralLatchIfReady()
                return .consume
            }
            if active, currentModifiers.isEmpty {
                let shouldTrigger = shortcut.keyCode != nil && exactModifiersWereDown && !cancelled
                clearCandidate()
                return shouldTrigger ? .trigger : .consume
            }
            return .consume
        }

        ordinaryKeysDown.remove(keyCode)
        if requiresNeutralState {
            clearNeutralLatchIfReady()
            return .passThrough
        }
        if hasUnsupportedModifier || hasExtraModifiers(currentModifiers) { cancelActiveCandidate() }
        return .passThrough
    }

    private func hasExtraModifiers(_ modifiers: ShortcutModifiers) -> Bool {
        !modifiers.subtracting(shortcut.modifiers).isEmpty
    }

    private mutating func beginCandidate() {
        active = true
        cancelled = !ordinaryKeysDown.isEmpty || hasExtraModifiers(currentModifiers)
        exactModifiersWereDown = currentModifiers == shortcut.modifiers
        matchedKeyWasPressed = false
        matchedKeyWasReleased = false
    }

    private mutating func clearNeutralLatchIfReady() {
        if currentModifiers.isEmpty && ordinaryKeysDown.isEmpty && ownedKeyCode == nil {
            requiresNeutralState = false
        }
    }

    private mutating func cancelActiveCandidate() {
        if active { cancelled = true }
    }

    private mutating func clearCandidate() {
        active = false
        cancelled = false
        exactModifiersWereDown = false
        matchedKeyWasPressed = false
        matchedKeyWasReleased = false
    }
}
