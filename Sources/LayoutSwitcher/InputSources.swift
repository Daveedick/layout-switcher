import Carbon.HIToolbox
import Foundation
import LayoutSwitcherCore

/// Read and select the configured keyboard layouts used by the converter.
public enum InputSources {
    public static let abcID = "com.apple.keylayout.ABC"
    public static let russianWinID = "com.apple.keylayout.RussianWin"

    public struct Source: Equatable {
        public let id: String
        public let name: String
    }

    private struct KeyMap {
        let textByKey: [Int: String]
        let keyByCharacter: [Character: TypedKey]
    }

    // Maps contain copied layout data/results only; no TIS references escape the
    // main-thread operation that reads the source properties.
    private static var keyMaps: [String: KeyMap] = [:]

    /// Character produced by a physical key under the requested enabled layout.
    public static func text(for key: TypedKey, sourceID: String) -> String? {
        onMain {
            guard let map = keyMapOnMain(sourceID: sourceID) else { return nil }
            return map.textByKey[signature(key)]
        }
    }

    /// Physical key and modifiers that produce a character under the requested layout.
    /// The main typing row is preferred over the numeric keypad where both can produce it.
    public static func key(for character: Character, sourceID: String) -> TypedKey? {
        onMain {
            keyMapOnMain(sourceID: sourceID)?.keyByCharacter[character]
        }
    }

    public static func available() -> [Source] {
        onMain {
            availableOnMain()
        }
    }

    public static func currentID() -> String? {
        onMain {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
            return property(source, kTISPropertyInputSourceID)
        }
    }

    @discardableResult
    public static func select(id: String) -> Bool {
        onMain {
            guard let source = availableReference(id: id) else { return false }
            return TISSelectInputSource(source) == noErr
        }
    }

    public static func isAvailable(id: String) -> Bool {
        available().contains { $0.id == id }
    }

    /// Non-mutating diagnostic used by the app's `--self-check` mode.
    public static func availabilityReport() -> [String] {
        let ids = Set(available().map(\.id))
        return [abcID, russianWinID].map { id in
            "\(id): \(ids.contains(id) ? "available" : "missing")"
        }
    }

    private static func availableOnMain() -> [Source] {
        assert(Thread.isMainThread)
        // includeAllInstalled=false limits this list to enabled/usable sources.
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = property(source, kTISPropertyInputSourceID) else { return nil }
            let name = property(source, kTISPropertyLocalizedName) ?? id
            return Source(id: id, name: name)
        }
    }

    private static func availableReference(id: String) -> TISInputSource? {
        assert(Thread.isMainThread)
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { property($0, kTISPropertyInputSourceID) == id }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        assert(Thread.isMainThread)
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func keyMapOnMain(sourceID: String) -> KeyMap? {
        assert(Thread.isMainThread)
        if let cached = keyMaps[sourceID] { return cached }

        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue!
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first(where: { property($0, kTISPropertyInputSourceID) == sourceID }),
              let propertyValue = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(propertyValue).takeUnretainedValue()
        let data = Data(bytes: CFDataGetBytePtr(cfData), count: CFDataGetLength(cfData))
        guard !data.isEmpty else { return nil }

        var textByKey: [Int: String] = [:]
        var keyByCharacter: [Character: TypedKey] = [:]
        // ANSI text keys first, then keypad keys; both Shift and Caps states matter.
        let keyCodes: [UInt16] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
            33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50,
            49, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92
        ]
        for keyCode in keyCodes {
            // Prefer explicit Shift over relying on the user's persistent Caps Lock
            // state when several physical states produce the same character.
            for caps in [false, true] {
                for shift in [false, true] {
                    let key = TypedKey(keyCode: keyCode, shift: shift, caps: caps)
                    guard let text = translateOnMain(key, layout: data), isPrintable(text),
                          text.count == 1, let character = text.first else { continue }
                    textByKey[signature(key)] = text
                    if keyByCharacter[character] == nil { keyByCharacter[character] = key }
                }
            }
        }
        let map = KeyMap(textByKey: textByKey, keyByCharacter: keyByCharacter)
        keyMaps[sourceID] = map
        return map
    }

    private static func translateOnMain(_ key: TypedKey, layout: Data) -> String? {
        assert(Thread.isMainThread)
        return layout.withUnsafeBytes { raw -> String? in
            guard let pointer = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let modifiers = (key.shift ? UInt32(shiftKey >> 8) : 0)
                | (key.caps ? UInt32(alphaLock >> 8) : 0)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                pointer,
                key.keyCode,
                UInt16(kUCKeyActionDown),
                modifiers & 0xFF,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: characters, count: Int(length))
        }
    }

    private static func isPrintable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar == " " || !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func signature(_ key: TypedKey) -> Int {
        Int(key.keyCode) | (key.shift ? 1 << 16 : 0) | (key.caps ? 1 << 17 : 0)
    }

    private static func onMain<T>(_ operation: () -> T) -> T {
        // Carbon's input-source manager asserts main-queue ownership. Keep the entire
        // operation, including property reads and reference lifetimes, on the main thread.
        if Thread.isMainThread { return operation() }
        return DispatchQueue.main.sync(execute: operation)
    }
}
