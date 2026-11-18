import Foundation

/// A physical key and the two keyboard states that affect its character.
public struct TypedKey: Equatable {
    public let keyCode: UInt16
    public let shift: Bool
    public let caps: Bool

    public init(keyCode: UInt16, shift: Bool, caps: Bool) {
        self.keyCode = keyCode
        self.shift = shift
        self.caps = caps
    }
}

/// Bounded history of printable physical keys for converting the most recent word.
/// Physical-stroke tracking is adapted from MIT ShiftSwitch (commit
/// 69099f0601ee66ca620a75fe216c6a8d2fe49452), with word-boundary state kept pure here.
public struct TypedKeyBuffer {
    public static let maximumKeys = 256

    private static let ansiKeys: Set<UInt16> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50
    ]
    private static let keypadKeys: Set<UInt16> = [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    private var storage: [TypedKey] = []
    private var invalidUntilBoundary = false

    public init() {}

    public var keys: [TypedKey] { storage }

    /// Tracks ANSI and numeric-keypad printable keys. Space is the only word boundary
    /// retained; other non-printable keys invalidate the current typing context.
    public mutating func append(_ key: TypedKey) {
        if key.keyCode == 49 { // ANSI Space
            if invalidUntilBoundary {
                storage.removeAll(keepingCapacity: true)
                invalidUntilBoundary = false
            } else if !storage.isEmpty {
                guard storage.count < Self.maximumKeys else {
                    invalidateUntilBoundary()
                    return
                }
                storage.append(key)
            }
            return
        }

        guard Self.isPrintablePhysicalKey(key.keyCode) else {
            reset()
            return
        }

        if invalidUntilBoundary { return }
        if storage.last?.keyCode == 49 { storage.removeAll(keepingCapacity: true) }
        guard storage.count < Self.maximumKeys else {
            invalidateUntilBoundary()
            return
        }
        storage.append(key)
    }

    public mutating func backspace() {
        guard !invalidUntilBoundary, !storage.isEmpty else { return }
        storage.removeLast()
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        invalidUntilBoundary = false
    }

    private mutating func invalidateUntilBoundary() {
        storage.removeAll(keepingCapacity: true)
        invalidUntilBoundary = true
    }

    private static func isPrintablePhysicalKey(_ keyCode: UInt16) -> Bool {
        // macOS virtual key codes for ANSI printable keys, excluding Space, plus
        // keypad digits and operators. Non-text keys such as Return, Tab, Delete,
        // arrows, keypad Enter/Clear and function keys deliberately reset the buffer.
        return ansiKeys.contains(keyCode) || keypadKeys.contains(keyCode)
    }
}
