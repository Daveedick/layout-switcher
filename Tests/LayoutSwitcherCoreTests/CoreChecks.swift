import Foundation
import LayoutSwitcherCore

@main
enum CoreChecks {
    private static var passed = 0

    static func main() {
        do {
            try run("ABC ↔ Russian mapping", testLayoutConversion)
            try run("mixed-script token conversion", testMixedScriptConversion)
            try run("letterless rejection", testRejectedInput)
            try run("modifier release and cancellation", testModifierChord)
            try run("modifier state order and other modifiers", testModifierOrderAndCancellation)
            try run("shortcut validation and decoding", testKeyboardShortcutValidation)
            try run("shortcut exact matching and release", testShortcutRecognition)
            try run("shortcut cancellation and paired key-up", testShortcutCancellationAndOwnership)
            try run("word boundaries, spaces, and backspace", testWordBuffer)
            try run("buffer invalidation and overflow", testBufferInvalidation)
            try run("physical key buffer and modifier states", testTypedKeyBuffer)
            try run("physical key buffer invalidation", testTypedKeyBufferInvalidation)
            try run("safe recent-word replacement range", testReplacementPlanner)
            print("Core checks passed: \(passed)")
        } catch {
            fputs("Core checks failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ check: () throws -> Void) throws {
        try check()
        passed += 1
        print("PASS \(name)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }

    private static func testLayoutConversion() throws {
        let toRussian = LayoutConverter.convert("ghbdtn, QAZ `~!?")
        try expect(toRussian?.text == "приветб ЙФЯ ёЁ!,", "ABC mapping/case/punctuation mismatch")
        try expect(toRussian?.targetInputSourceID == LayoutConverter.russianWinInputSourceID, "wrong Russian source")

        let toABC = LayoutConverter.convert("Привет, мир! 🌿")
        try expect(toABC?.text == "Ghbdtn? vbh! 🌿", "Russian mapping or Unicode preservation mismatch")
        try expect(toABC?.targetInputSourceID == LayoutConverter.abcInputSourceID, "wrong ABC source")
        try expect(LayoutConverter.convert("a\\b|c")?.text == "ф\\и/с", "backslash row mapping mismatch")
        try expect(LayoutConverter.convert("ф\\и/с")?.text == "a\\b|c", "reverse backslash row mapping mismatch")
        try expect(LayoutConverter.convert("hello 世界")?.text == "руддщ 世界", "unrelated Unicode should remain")
        try expect(LayoutConverter.convert("мир 世界")?.text == "vbh 世界", "unrelated Unicode should remain")
    }

    private static func testRejectedInput() throws {
        try expect(LayoutConverter.convert("12345 !? 🌿") == nil, "letterless input should be rejected")
        try expect(LayoutConverter.convert("") == nil, "empty input should be rejected")
        try expect(LayoutConverter.convert("é") == nil, "unmapped letter should not report a no-op conversion")
    }

    private static func testMixedScriptConversion() throws {
        let russianThenLatin = LayoutConverter.convert("привет hello")
        try expect(russianThenLatin?.text == "ghbdtn руддщ", "each homogeneous token should convert in its own direction")
        try expect(russianThenLatin?.targetInputSourceID == LayoutConverter.russianWinInputSourceID, "default mixed target should follow the last recognized letter")

        let latinThenRussian = LayoutConverter.convert("hello привет")
        try expect(latinThenRussian?.text == "руддщ ghbdtn", "reverse mixed token conversion mismatch")
        try expect(latinThenRussian?.targetInputSourceID == LayoutConverter.abcInputSourceID, "last Russian letter should choose ABC without a source hint")
        try expect(LayoutConverter.convert("hello привет", currentInputSourceID: LayoutConverter.abcInputSourceID)?.targetInputSourceID == LayoutConverter.russianWinInputSourceID, "ABC hint should choose RussianWin for mixed text")
        try expect(LayoutConverter.convert("hello привет", currentInputSourceID: LayoutConverter.russianWinInputSourceID)?.targetInputSourceID == LayoutConverter.abcInputSourceID, "RussianWin hint should choose ABC for mixed text")

        let withinToken = LayoutConverter.convert("приветhello!?")
        try expect(withinToken?.text == "ghbdtnруддщ!?", "mixed token should swap recognized letters and preserve ambiguous punctuation")
        let withWhitespace = LayoutConverter.convert("привет  hello\nмир ?")
        try expect(withWhitespace?.text == "ghbdtn  руддщ\nvbh ?", "whitespace and punctuation-only tokens should be preserved")
    }

    private static func testModifierChord() throws {
        var chord = ModifierChord()
        try expect(!chord.update(option: true, command: false, otherModifier: false), "must wait for Command")
        try expect(!chord.update(option: true, command: true, otherModifier: false), "must wait for release")
        try expect(!chord.update(option: false, command: true, otherModifier: false), "must wait for final release")
        try expect(chord.update(option: false, command: false, otherModifier: false), "release should trigger once")
        try expect(!chord.update(option: false, command: false, otherModifier: false), "release must not repeat")

        var shortcut = ModifierChord()
        try expect(!shortcut.update(option: true, command: false, otherModifier: false), "unexpected trigger")
        shortcut.cancelForKeyDown()
        try expect(!shortcut.update(option: true, command: true, otherModifier: false), "ordinary shortcut should cancel")
        try expect(!shortcut.update(option: false, command: false, otherModifier: false), "cancelled shortcut must not fire")
    }

    private static func testModifierOrderAndCancellation() throws {
        var reverse = ModifierChord()
        try expect(!reverse.update(option: false, command: true, otherModifier: false), "must wait for Option")
        try expect(!reverse.update(option: true, command: true, otherModifier: false), "must wait for release")
        try expect(!reverse.update(option: true, command: false, otherModifier: false), "must wait for final release")
        try expect(reverse.update(option: false, command: false, otherModifier: false), "reverse order should trigger on final release")
        try expect(!reverse.update(option: false, command: false, otherModifier: false), "must only trigger once")

        var shift = ModifierChord()
        try expect(!shift.update(option: false, command: false, otherModifier: true), "Shift must not trigger")
        try expect(!shift.update(option: true, command: false, otherModifier: true), "Shift chord must stay cancelled")
        try expect(!shift.update(option: true, command: false, otherModifier: false), "releasing Shift must not revive it")
        try expect(!shift.update(option: true, command: true, otherModifier: false), "later Command must not revive it")
        try expect(!shift.update(option: false, command: false, otherModifier: false), "cancelled gesture must not fire")

        var preKey = ModifierChord()
        preKey.cancelForKeyDown()
        try expect(!preKey.update(option: true, command: true, otherModifier: false), "ordinary earlier typing must not poison a future chord")
        try expect(preKey.update(option: false, command: false, otherModifier: false), "future clean chord should fire")
        preKey.reset()
    }

    private static func testKeyboardShortcutValidation() throws {
        try expect(KeyboardShortcut.defaultShortcut.isValid, "default Option+Command shortcut should be valid")
        try expect(!KeyboardShortcut(modifiers: [.command], keyCode: nil).isValid,
                   "modifier-only shortcut needs at least two modifiers")
        try expect(!KeyboardShortcut(modifiers: [], keyCode: nil).isValid,
                   "empty shortcut should be invalid")
        try expect(!KeyboardShortcut(modifiers: [.shift], keyCode: 12).isValid,
                   "Shift-only key combination should be invalid")
        try expect(KeyboardShortcut(modifiers: [.shift, .command], keyCode: 12).isValid,
                   "Shift with Command should be valid")
        for keyCode: UInt16 in [53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 128] {
            try expect(!KeyboardShortcut(modifiers: [.command], keyCode: keyCode).isValid,
                       "reserved or out-of-range key code should be invalid: \(keyCode)")
        }
        try expect(!KeyboardShortcut(modifiers: ShortcutModifiers(rawValue: 0x10), keyCode: nil).isValid,
                   "unknown modifier bits should be invalid")

        let invalidModifierOnlyJSON = Data(#"{"modifiers":{"rawValue":1},"keyCode":null}"#.utf8)
        do {
            _ = try JSONDecoder().decode(KeyboardShortcut.self, from: invalidModifierOnlyJSON)
            throw CheckFailure(message: "decoder accepted invalid modifier-only shortcut")
        } catch is DecodingError {
            // Expected: decoded values must be valid before settings can install them.
        }
    }

    private static func testShortcutRecognition() throws {
        var defaultRecognizer = ShortcutRecognizer()
        try expect(defaultRecognizer.modifiersChanged(.option) == .passThrough, "Option alone must not trigger")
        try expect(defaultRecognizer.modifiersChanged([.option, .command]) == .passThrough,
                   "default shortcut waits for release")
        try expect(defaultRecognizer.modifiersChanged(.command) == .passThrough,
                   "release order should not matter")
        try expect(defaultRecognizer.modifiersChanged([]) == .trigger,
                   "default shortcut triggers on final modifier release")
        try expect(defaultRecognizer.modifiersChanged([]) == .passThrough,
                   "default shortcut should fire once")

        var reverse = ShortcutRecognizer()
        _ = reverse.modifiersChanged(.command)
        _ = reverse.modifiersChanged([.command, .option])
        _ = reverse.modifiersChanged(.option)
        try expect(reverse.modifiersChanged([]) == .trigger,
                   "reverse modifier press order should trigger once")

        var appShortcut = ShortcutRecognizer()
        try expect(appShortcut.keyDown(keyCode: 12, modifiers: .command) == .passThrough,
                   "ordinary Command+Q key-down must pass to the app")
        try expect(appShortcut.keyUp(keyCode: 12, modifiers: []) == .passThrough,
                   "ordinary app key-up must pass through")
        _ = appShortcut.modifiersChanged(.command)
        try expect(appShortcut.modifiersChanged([]) == .passThrough,
                   "nonmatching app shortcut must not trigger conversion")

        let custom = KeyboardShortcut(modifiers: [.command, .option], keyCode: 14)
        var keyed = ShortcutRecognizer(shortcut: custom)
        _ = keyed.modifiersChanged(.option)
        _ = keyed.modifiersChanged([.command, .option])
        try expect(keyed.keyDown(keyCode: 14, modifiers: [.command, .option]) == .consume,
                   "matching custom key-down should be consumed")
        try expect(keyed.keyDown(keyCode: 14, modifiers: [.command, .option], isRepeat: true) == .consume,
                   "matching auto-repeat should remain consumed")
        try expect(keyed.keyUp(keyCode: 14, modifiers: [.command, .option]) == .consume,
                   "paired custom key-up should be consumed")
        _ = keyed.modifiersChanged(.command)
        try expect(keyed.modifiersChanged([]) == .trigger,
                   "custom shortcut fires once after key-up and all modifiers release")
        try expect(keyed.keyUp(keyCode: 14, modifiers: []) == .passThrough,
                   "completed key-up must not fire twice")

        var keyUpLast = ShortcutRecognizer(shortcut: custom)
        _ = keyUpLast.modifiersChanged([.command, .option])
        _ = keyUpLast.keyDown(keyCode: 14, modifiers: [.command, .option])
        _ = keyUpLast.modifiersChanged([])
        try expect(keyUpLast.keyUp(keyCode: 14, modifiers: []) == .trigger,
                   "shortcut should fire when the key-up follows final modifier release")
    }

    private static func testShortcutCancellationAndOwnership() throws {
        let custom = KeyboardShortcut(modifiers: [.command, .option], keyCode: 14)
        var cancelled = ShortcutRecognizer(shortcut: custom)
        _ = cancelled.modifiersChanged([.command, .option])
        try expect(cancelled.keyDown(keyCode: 14, modifiers: [.command, .option]) == .consume,
                   "matched down should be owned before cancellation")
        try expect(cancelled.keyDown(keyCode: 12, modifiers: [.command, .option]) == .passThrough,
                   "an extra ordinary key must pass through and cancel")
        try expect(cancelled.keyUp(keyCode: 14, modifiers: [.command, .option]) == .consume,
                   "owned key-up remains consumed after cancellation")
        _ = cancelled.modifiersChanged(.command)
        try expect(cancelled.modifiersChanged([]) == .passThrough,
                   "cancelled shortcut must not trigger on release")

        var functionCancelled = ShortcutRecognizer(shortcut: custom)
        _ = functionCancelled.modifiersChanged([.command, .option])
        _ = functionCancelled.keyDown(keyCode: 14, modifiers: [.command, .option])
        try expect(functionCancelled.modifiersChanged([.command, .option], hasUnsupportedModifier: true) == .passThrough,
                   "unsupported Fn/Help modifier should cancel the candidate")
        try expect(functionCancelled.keyUp(keyCode: 14, modifiers: [.command, .option]) == .consume,
                   "owned key-up remains consumed after unsupported modifier cancellation")
        _ = functionCancelled.modifiersChanged(.command)
        try expect(functionCancelled.modifiersChanged([]) == .passThrough,
                   "unsupported-modifier cancellation must not trigger")

        var updated = ShortcutRecognizer(shortcut: custom)
        _ = updated.modifiersChanged([.command, .option])
        _ = updated.keyDown(keyCode: 14, modifiers: [.command, .option])
        updated.updateShortcut(KeyboardShortcut(modifiers: [.control, .option], keyCode: 3))
        _ = updated.modifiersChanged([.control, .option])
        try expect(updated.keyDown(keyCode: 3, modifiers: [.control, .option]) == .passThrough,
                   "a new shortcut must not take ownership while the old key-up is pending")
        _ = updated.keyUp(keyCode: 3, modifiers: [.control, .option])
        try expect(updated.keyUp(keyCode: 14, modifiers: []) == .consume,
                   "settings update must retain ownership of the old paired key-up")
        try expect(updated.modifiersChanged([]) == .passThrough,
                   "settings update must cancel the old candidate")
        _ = updated.modifiersChanged([.control, .option])
        try expect(updated.keyDown(keyCode: 3, modifiers: [.control, .option]) == .consume,
                   "updated shortcut should be recognized")
        try expect(updated.keyUp(keyCode: 3, modifiers: []) == .trigger,
                   "updated shortcut should complete on its final key-up")

        var modifierOnlyCancelled = ShortcutRecognizer()
        _ = modifierOnlyCancelled.modifiersChanged(.option)
        _ = modifierOnlyCancelled.keyDown(keyCode: 12, modifiers: .option)
        try expect(modifierOnlyCancelled.modifiersChanged([.option, .command]) == .passThrough,
                   "ordinary key during modifier-only candidate must cancel")
        _ = modifierOnlyCancelled.keyUp(keyCode: 12, modifiers: [.option, .command])
        _ = modifierOnlyCancelled.modifiersChanged(.command)
        try expect(modifierOnlyCancelled.modifiersChanged([]) == .passThrough,
                   "cancelled modifier-only candidate must not revive")

        var functionBeforeModifiers = ShortcutRecognizer(shortcut: custom)
        _ = functionBeforeModifiers.modifiersChanged(.option)
        try expect(functionBeforeModifiers.modifiersChanged(.option, hasUnsupportedModifier: true) == .passThrough,
                   "Fn during a partial candidate should cancel it")
        _ = functionBeforeModifiers.modifiersChanged(.option)
        _ = functionBeforeModifiers.modifiersChanged([.command, .option])
        try expect(functionBeforeModifiers.keyDown(keyCode: 14, modifiers: [.command, .option]) == .passThrough,
                   "releasing Fn must not revive the already-cancelled candidate")
        _ = functionBeforeModifiers.keyUp(keyCode: 14, modifiers: [.command, .option])
        _ = functionBeforeModifiers.modifiersChanged(.command)
        try expect(functionBeforeModifiers.modifiersChanged([]) == .passThrough,
                   "Fn cancellation should persist through final modifier release")
    }

    private static func testWordBuffer() throws {
        var buffer = WordBuffer()
        buffer.append("old words new")
        try expect(buffer.text == "new", "only latest token should remain")
        buffer.append("  ")
        try expect(buffer.text == "new  ", "trailing ASCII spaces should remain")
        buffer.append("word")
        try expect(buffer.text == "word", "next word should replace prior token")
        buffer.append(" ")
        buffer.backspace()
        try expect(buffer.text == "word", "backspace should remove trailing space")
        buffer.replace(with: "слово ")
        try expect(buffer.text == "слово ", "replace should install new token")
        buffer.backspace()
        try expect(buffer.text == "слово", "backspace should remove last character")
        buffer.append("\tnew\nnext\u{00A0}tail")
        try expect(buffer.text == "tail", "control and non-ASCII whitespace should reset")
    }

    private static func testBufferInvalidation() throws {
        var uncertain = WordBuffer()
        uncertain.append("hello🌿ignored")
        try expect(uncertain.text.isEmpty, "uncertain Unicode must invalidate token")
        uncertain.append(" ")
        uncertain.append("word")
        try expect(uncertain.text == "word", "next boundary should allow a fresh token")

        var overflow = WordBuffer()
        overflow.append(String(repeating: "a", count: WordBuffer.maximumCharacters + 1))
        try expect(overflow.text.isEmpty, "overflow must clear token")
        overflow.append("continued")
        try expect(overflow.text.isEmpty, "overflow should invalidate through current word")
        overflow.append(" next")
        try expect(overflow.text == "next", "boundary should recover the buffer")

        overflow.reset()
        overflow.append("ready")
        try expect(overflow.text == "ready", "reset should recover buffer")
    }

    private static func testTypedKeyBuffer() throws {
        var buffer = TypedKeyBuffer()
        let a = TypedKey(keyCode: 0, shift: false, caps: false)
        let shifted = TypedKey(keyCode: 0, shift: true, caps: false)
        let capped = TypedKey(keyCode: 0, shift: false, caps: true)
        let space = TypedKey(keyCode: 49, shift: false, caps: false)

        buffer.append(a)
        buffer.append(shifted)
        try expect(buffer.keys == [a, shifted], "physical key and Shift state must be retained")
        buffer.append(space)
        buffer.append(space)
        try expect(buffer.keys == [a, shifted, space, space], "trailing spaces should be preserved")
        buffer.append(capped)
        try expect(buffer.keys == [capped], "first non-space key should start a fresh word")
        buffer.backspace()
        try expect(buffer.keys.isEmpty, "backspace should remove the latest physical key")
        buffer.append(capped)
        try expect(buffer.keys == [capped], "Caps state must be retained")
    }

    private static func testTypedKeyBufferInvalidation() throws {
        var buffer = TypedKeyBuffer()
        buffer.append(TypedKey(keyCode: 0, shift: false, caps: false))
        buffer.append(TypedKey(keyCode: 123, shift: false, caps: false)) // Left arrow
        try expect(buffer.keys.isEmpty, "navigation key must reset the buffer")

        buffer.append(TypedKey(keyCode: 0, shift: false, caps: false))
        buffer.append(TypedKey(keyCode: 55, shift: false, caps: false)) // Command modifier
        try expect(buffer.keys.isEmpty, "modifier key code must reset the buffer")

        buffer.reset()
        let a = TypedKey(keyCode: 0, shift: false, caps: false)
        for _ in 0..<TypedKeyBuffer.maximumKeys { buffer.append(a) }
        try expect(buffer.keys.count == TypedKeyBuffer.maximumKeys, "buffer should accept its exact maximum")
        buffer.append(a)
        buffer.append(TypedKey(keyCode: 1, shift: false, caps: false))
        try expect(buffer.keys.isEmpty, "overflow must invalidate the word, including later suffix keys")
        buffer.append(TypedKey(keyCode: 49, shift: false, caps: false))
        let recovered = TypedKey(keyCode: 2, shift: false, caps: false)
        buffer.append(recovered)
        try expect(buffer.keys == [recovered], "space boundary should allow the next word")
    }

    private static func testReplacementPlanner() throws {
        let afterSpaces = "prior\tword  "
        let afterSpacesRange = ReplacementPlanner.recentWordRange(
            in: afterSpaces, caretUTF16: (afterSpaces as NSString).length, recentText: "word  "
        )
        try expect(NSEqualRanges(afterSpacesRange ?? NSRange(location: -1, length: 0), NSRange(location: 6, length: 6)), "token and repeated spaces should select exactly the recent word")

        let atDocumentStart = "hello"
        try expect(ReplacementPlanner.recentWordRange(in: atDocumentStart, caretUTF16: 5, recentText: "hello") == NSRange(location: 0, length: 5), "document-start token should be accepted")

        let olderWordUnchanged = "older latest"
        try expect(ReplacementPlanner.recentWordRange(in: olderWordUnchanged, caretUTF16: 12, recentText: "latest") == NSRange(location: 6, length: 6), "range should exclude the previous word")

        let emojiPrefix = "🌿 word "
        let emojiCaret = (emojiPrefix as NSString).length
        try expect(ReplacementPlanner.recentWordRange(in: emojiPrefix, caretUTF16: emojiCaret, recentText: "word ") == NSRange(location: 3, length: 5), "UTF-16 offsets after surrogate pairs should be correct")

        try expect(ReplacementPlanner.recentWordRange(in: "prefixword", caretUTF16: 10, recentText: "word") == nil, "suffix of older word must not be replaced")
        try expect(ReplacementPlanner.recentWordRange(in: "word", caretUTF16: 4, recentText: "stale") == nil, "stale buffer must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "word", caretUTF16: -1, recentText: "word") == nil, "negative caret must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "word", caretUTF16: 5, recentText: "word") == nil, "out-of-range caret must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "a🌿b", caretUTF16: 2, recentText: "a") == nil, "caret inside a surrogate pair must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "e\u{301}x", caretUTF16: 1, recentText: "e") == nil, "range splitting a combining Character must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "line\nword", caretUTF16: 9, recentText: "line\nword") == nil, "newline inside candidate must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "tab\tword", caretUTF16: 8, recentText: "tab\tword") == nil, "tab inside candidate must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "  ", caretUTF16: 2, recentText: "  ") == nil, "empty token with only spaces must be rejected")
        try expect(ReplacementPlanner.recentWordRange(in: "ok", caretUTF16: 2, recentText: String(repeating: "a", count: WordBuffer.maximumCharacters + 1)) == nil, "unbounded candidate must be rejected")
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
