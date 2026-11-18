import Foundation

public struct WordBuffer {
    public static let maximumCharacters = 256

    private var buffer = ""
    private var invalidUntilBoundary = false

    public init() {}

    public var text: String { buffer }

    public mutating func append(_ text: String) {
        for character in text {
            if character == " " {
                if invalidUntilBoundary {
                    buffer = ""
                    invalidUntilBoundary = false
                }
                if !buffer.isEmpty {
                    if buffer.count >= Self.maximumCharacters {
                        invalidateUntilBoundary()
                    } else {
                        buffer.append(character)
                    }
                }
                continue
            }

            if character == "\n" || character == "\r" || character == "\t" || Self.containsControl(character) {
                reset()
                continue
            }

            if Self.isOtherWhitespace(character) {
                reset()
                continue
            }

            if invalidUntilBoundary { continue }
            if Self.isUncertain(character) {
                invalidateUntilBoundary()
                continue
            }

            // The first non-space character after a completed token starts a new word.
            if buffer.last == " " { buffer = "" }
            if buffer.count >= Self.maximumCharacters {
                invalidateUntilBoundary()
            } else {
                buffer.append(character)
            }
        }
    }

    public mutating func backspace() {
        guard !invalidUntilBoundary, !buffer.isEmpty else { return }
        buffer.removeLast()
    }

    public mutating func reset() {
        buffer = ""
        invalidUntilBoundary = false
    }

    public mutating func replace(with text: String) {
        reset()
        append(text)
    }

    private mutating func invalidateUntilBoundary() {
        buffer = ""
        invalidUntilBoundary = true
    }

    private static func containsControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isOtherWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isUncertain(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            let isASCII = value <= 0x7F
            let isLatin = (0x00C0...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value)
            let isCyrillic = (0x0400...0x052F).contains(value) || (0x1C80...0x1C8F).contains(value)
                || (0x2DE0...0x2DFF).contains(value) || (0xA640...0xA69F).contains(value)
            let isCombiningMark = CharacterSet.nonBaseCharacters.contains(scalar)
            if !isASCII && !isLatin && !isCyrillic && !isCombiningMark { return true }
        }
        return false
    }
}
