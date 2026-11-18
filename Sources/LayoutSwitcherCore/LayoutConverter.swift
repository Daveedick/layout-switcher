import Foundation

public struct LayoutConversion: Equatable {
    public let text: String
    public let targetInputSourceID: String

    public init(text: String, targetInputSourceID: String) {
        self.text = text
        self.targetInputSourceID = targetInputSourceID
    }
}

public enum LayoutConverter {
    public static let abcInputSourceID = "com.apple.keylayout.ABC"
    public static let russianWinInputSourceID = "com.apple.keylayout.RussianWin"

    // Each pair represents the same physical key on ABC and Russian – PC.
    private static let keyPairs: [(Character, Character)] = [
        ("`", "ё"), ("~", "Ё"),
        ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"),
        ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"),
        ("[", "х"), ("]", "ъ"),
        ("Q", "Й"), ("W", "Ц"), ("E", "У"), ("R", "К"), ("T", "Е"),
        ("Y", "Н"), ("U", "Г"), ("I", "Ш"), ("O", "Щ"), ("P", "З"),
        ("{", "Х"), ("}", "Ъ"),
        ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"),
        ("h", "р"), ("j", "о"), ("k", "л"), ("l", "д"),
        (";", "ж"), ("'", "э"),
        ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("G", "П"),
        ("H", "Р"), ("J", "О"), ("K", "Л"), ("L", "Д"),
        (":", "Ж"), ("\"", "Э"),
        ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"),
        ("n", "т"), ("m", "ь"), (",", "б"), (".", "ю"), ("/", "."),
        ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"),
        ("N", "Т"), ("M", "Ь"), ("<", "Б"), (">", "Ю"), ("?", ","),
        ("\\", "\\"), ("|", "/"),
        ("1", "1"), ("!", "!"), ("2", "2"), ("@", "\""),
        ("3", "3"), ("#", "№"), ("4", "4"), ("$", ";"),
        ("5", "5"), ("%", "%"), ("6", "6"), ("^", ":"),
        ("7", "7"), ("&", "?"), ("8", "8"), ("*", "*"),
        ("9", "9"), ("(", "("), ("0", "0"), (")", ")"),
        ("-", "-"), ("_", "_"), ("=", "="), ("+", "+"),
    ]

    private static let abcToRussian = Dictionary(uniqueKeysWithValues: keyPairs)
    private static let russianToABC = Dictionary(uniqueKeysWithValues: keyPairs.map { ($1, $0) })

    /// Reinterprets characters by physical key position. Non-Latin/Cyrillic Unicode is kept.
    /// Whitespace-delimited tokens are converted independently. In a token containing both
    /// scripts, recognized letters are mapped individually and punctuation is left unchanged.
    public static func convert(_ text: String, currentInputSourceID: String? = nil) -> LayoutConversion? {
        var hasLatin = false
        var hasCyrillic = false
        var lastScript: Script?
        for scalar in text.unicodeScalars {
            if isLatinLetter(scalar) {
                hasLatin = true
                lastScript = .latin
            }
            if isCyrillicLetter(scalar) {
                hasCyrillic = true
                lastScript = .cyrillic
            }
        }

        guard hasLatin || hasCyrillic else { return nil }
        let isMixedSelection = hasLatin && hasCyrillic
        let targetInputSourceID: String
        if isMixedSelection, currentInputSourceID == abcInputSourceID {
            targetInputSourceID = russianWinInputSourceID
        } else if isMixedSelection, currentInputSourceID == russianWinInputSourceID {
            targetInputSourceID = abcInputSourceID
        } else {
            targetInputSourceID = lastScript == .latin ? russianWinInputSourceID : abcInputSourceID
        }

        var output = ""
        var token = ""
        func flushToken() {
            guard !token.isEmpty else { return }
            let tokenHasLatin = token.unicodeScalars.contains(where: isLatinLetter)
            let tokenHasCyrillic = token.unicodeScalars.contains(where: isCyrillicLetter)
            if tokenHasLatin && tokenHasCyrillic {
                output.append(contentsOf: token.map { character in
                    if character.unicodeScalars.contains(where: isLatinLetter) {
                        return abcToRussian[character] ?? character
                    }
                    if character.unicodeScalars.contains(where: isCyrillicLetter) {
                        return russianToABC[character] ?? character
                    }
                    return character
                })
            } else if !tokenHasLatin && !tokenHasCyrillic && isMixedSelection {
                output.append(contentsOf: token)
            } else {
                let mapping = tokenHasLatin || (!tokenHasCyrillic && hasLatin) ? abcToRussian : russianToABC
                output.append(contentsOf: token.map { mapping[$0] ?? $0 })
            }
            token = ""
        }

        for character in text {
            if character.isWhitespace {
                flushToken()
                output.append(character)
            } else {
                token.append(character)
            }
        }
        flushToken()
        guard output != text else { return nil }
        return LayoutConversion(
            text: output,
            targetInputSourceID: targetInputSourceID
        )
    }

    private enum Script { case latin, cyrillic }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0400...0x052F, 0x1C80...0x1C8F,
             0x2DE0...0x2DFF, 0xA640...0xA69F:
            return true
        default:
            return false
        }
    }
}
