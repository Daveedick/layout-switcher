public struct ModifierChord {
    private var candidate = false
    private var bothWereDown = false
    private var cancelled = false

    public init() {}

    /// Returns true once, on release, for an uninterrupted Option+Command gesture.
    public mutating func update(option: Bool, command: Bool, otherModifier: Bool) -> Bool {
        let anyModifierDown = option || command || otherModifier

        if !candidate && anyModifierDown {
            candidate = true
            cancelled = otherModifier
            bothWereDown = option && command && !otherModifier
        } else if candidate {
            if otherModifier { cancelled = true }
            if option && command && !otherModifier { bothWereDown = true }
        }

        guard !anyModifierDown else { return false }
        let shouldFire = candidate && bothWereDown && !cancelled
        clearGesture()
        return shouldFire
    }

    /// Any ordinary key makes the current modifier gesture a shortcut, not a chord.
    public mutating func cancelForKeyDown() {
        if candidate { cancelled = true }
    }

    public mutating func reset() {
        clearGesture()
    }

    private mutating func clearGesture() {
        candidate = false
        bothWereDown = false
        cancelled = false
    }
}
