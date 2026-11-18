import Foundation

/// Validates the text immediately before a caret before replacing the buffered recent word.
public enum ReplacementPlanner {
    /// Returns the UTF-16 range of the most recent token and its trailing ASCII spaces.
    /// The range is returned only when both ends are Unicode Character boundaries and the
    /// buffer is an exact UTF-16 match for the text immediately before the caret.
    public static func recentWordRange(in value: String, caretUTF16: Int, recentText: String) -> NSRange? {
        let valueUTF16Length = (value as NSString).length
        guard caretUTF16 >= 0, caretUTF16 <= valueUTF16Length,
              !recentText.isEmpty,
              recentText.count <= WordBuffer.maximumCharacters,
              recentText.utf16.count <= WordBuffer.maximumCharacters * 4,
              hasCharacterBoundary(atUTF16: caretUTF16, in: value)
        else { return nil }

        let recentUnits = Array(recentText.utf16)
        guard recentUnits.count <= caretUTF16 else { return nil }
        let startUTF16 = caretUTF16 - recentUnits.count
        guard hasCharacterBoundary(atUTF16: startUTF16, in: value) else { return nil }

        let range = NSRange(location: startUTF16, length: recentUnits.count)
        let actualText = (value as NSString).substring(with: range)
        guard Array(actualText.utf16) == recentUnits else { return nil }

        let characters = Array(recentText)
        let tokenEnd = characters.lastIndex(where: { $0 != " " }).map { $0 + 1 } ?? 0
        guard tokenEnd > 0 else { return nil }
        let token = characters[..<tokenEnd]
        guard !token.contains(where: isWhitespaceOrControl) else { return nil }
        guard !characters.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return nil }

        if startUTF16 > 0 {
            let priorIndex = String.Index(utf16Offset: startUTF16, in: value)
            guard let priorCharacter = value[..<priorIndex].last,
                  priorCharacter.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) })
            else { return nil }
        }

        return range
    }

    private static func hasCharacterBoundary(atUTF16 offset: Int, in value: String) -> Bool {
        let utf16View = value.utf16
        guard offset >= 0, let utf16Index = utf16View.index(utf16View.startIndex, offsetBy: offset, limitedBy: utf16View.endIndex),
              let stringIndex = String.Index(utf16Index, within: value)
        else { return false }
        return stringIndex == value.endIndex || value.indices.contains(stringIndex)
    }

    private static func isWhitespaceOrControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}
