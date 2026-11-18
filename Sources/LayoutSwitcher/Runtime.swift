import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import LayoutSwitcherCore
import os

/// Keyboard observer and guarded layout replacement runtime.
/// The bounded physical-key capture and retype path is adapted from ShiftSwitch
/// (MIT ShiftSwitch reference, commit 69099f0601ee66ca620a75fe216c6a8d2fe49452).
/// Captured characters are reconstructed only for the active conversion and are never logged or persisted.
final class SwitcherRuntime {
    private struct PendingService {
        let context: FocusContext
        let generation: UInt64
        let deadline: DispatchTime
        let sourceID: String?
    }

    private enum RecentWordAXState {
        case unavailable
        case verified(value: String, range: CFRange)
        case selectionActive
    }

    private enum ExpectedValueState {
        case unavailable
        case expected(original: String, replacement: String)
        case mismatch
    }

    private struct HeldEvent {
        let event: CGEvent
        let type: CGEventType
    }

    private struct PreparedKeyEvent {
        let down: CGEvent
        let up: CGEvent
    }

    private static let ownEventTag: Int64 = 0x4C535752
    private static let replayEventTag: Int64 = 0x4C535250
    private static let statusLogger = Logger(subsystem: "local.layout-switcher.app", category: "RuntimeStatus")
    // Physical fallback stays bounded, while writable AX and Services can handle larger selections.
    private static let maximumSyntheticUTF16Length = 256
    private static let maximumServiceUTF16Length = 16_384
    private static let maximumPhysicalReplacementKeys = 256
    private static let maximumHeldEvents = 128
    private static let maximumHoldNanoseconds: UInt64 = 1_500_000_000
    private static let maximumClipboardHoldNanoseconds: UInt64 = 2_500_000_000
    // ClipboardReplacement.finish(false) waits 850ms, then retries restoration up to three times.
    private static let maximumClipboardFinishNanoseconds: UInt64 = 1_150_000_000
    private static let maximumReadbackNanoseconds: UInt64 = 200_000_000
    private static let mutationSafetyMarginNanoseconds: UInt64 = 100_000_000
    private static let clipboardSafetyMarginNanoseconds: UInt64 = 300_000_000
    private let statusHandler: (String) -> Void

    // AX IPC is serialized off-main. The event tap never waits for this queue.
    private let stateQueue = DispatchQueue(label: "local.layout-switcher.state", qos: .userInitiated)
    private let axQueue = DispatchQueue(label: "local.layout-switcher.ax", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    private let generationLock = NSLock()
    private let serviceLock = NSLock()
    private let mutationLock = NSLock()
    private var lifecycleRunning = false
    private var lifecyclePaused = false
    private var eventGeneration: UInt64 = 0
    private var pendingService: PendingService?
    private var expectedSourceID: String?
    private var expectedSourceDeadline: DispatchTime = .now()
    private var mutationActive = false
    private var mutationCancelled = false
    private var mutationStartedAt: UInt64 = 0
    private var mutationHoldBudgetNanoseconds: UInt64 = 0
    private var heldEvents: [HeldEvent] = []
    private var mutationContext: FocusContext?

    private var running = false
    private var paused = false
    private var buffer = TypedKeyBuffer()
    private var bufferSourceID: String?
    // Event-tap callbacks and lifecycle updates run on main; keep recognition off worker queues.
    private var shortcutRecognizer: ShortcutRecognizer
    private var shortcutRecording = false
    private var conversionBusy = false
    private var testShortcutArmed = false
    private var testShortcutF12Released = false
    // Event-tap-thread marker for a diagnostic keydown so its keyup is logged even if flags changed.
    private var diagnosticShortcutKeyCode: UInt16?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init(shortcut: KeyboardShortcut = .defaultShortcut, onStatus: @escaping (String) -> Void) {
        self.shortcutRecognizer = ShortcutRecognizer(shortcut: shortcut)
        self.statusHandler = onStatus
    }

    var isRunning: Bool { lifecycleLock.withLock { lifecycleRunning && !lifecyclePaused } }

    func start() {
        DispatchQueue.main.async { [weak self] in self?.startOnMain() }
    }

    func stop() {
        if Thread.isMainThread { stopOnMain() }
        else { DispatchQueue.main.async { [weak self] in self?.stopOnMain() } }
    }

    private func stopOnMain() {
        cancelMutationAndReplayHeld()
        advanceGeneration()
        shortcutRecognizer.reset()
        shortcutRecording = false
        setLifecycle(running: false, paused: false)
        removeTap()
        removeWorkspaceObservers()
        clearPendingService()
        stateQueue.async {
            self.running = false
            self.paused = false
            self.resetStateLocked()
        }
        publish("Stopped")
    }

    func setPaused(_ value: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setPaused(value) }
            return
        }
        shortcutRecognizer.cancelGesture()
        if value { cancelMutationAndReplayHeld() }
        advanceGeneration()
        lifecycleLock.withLock { lifecyclePaused = value }
        clearPendingService()
        stateQueue.async {
            self.paused = value
            self.resetStateLocked()
        }
        publish(value ? "Приостановлено" : "Работает")
    }

    /// Main-thread settings entry point. Invalid values are ignored defensively.
    func updateShortcut(_ shortcut: KeyboardShortcut) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateShortcut(shortcut) }
            return
        }
        guard shortcut.isValid else { return }
        shortcutRecognizer.updateShortcut(shortcut)
        advanceGeneration()
        clearPendingService()
        stateQueue.async { [weak self] in self?.resetStateLocked() }
    }

    /// While recording, ordinary keys pass to the settings UI and never enter the word buffer.
    func setShortcutRecording(_ recording: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setShortcutRecording(recording) }
            return
        }
        guard shortcutRecording != recording else { return }
        shortcutRecording = recording
        shortcutRecognizer.cancelGesture()
        advanceGeneration()
        clearPendingService()
        stateQueue.async { [weak self] in self?.resetStateLocked() }
    }

    func retryPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceGeneration()
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.PuntoSwitcher").isEmpty else {
                self.publish("Сначала завершите Punto Switcher, затем возобновите")
                return
            }
            guard AXIsProcessTrusted(), self.installTap() else {
                self.publish("Разрешите Универсальный доступ и Мониторинг ввода")
                return
            }
            self.setLifecycle(running: true, paused: false)
            self.stateQueue.async { self.running = true; self.paused = false; self.resetStateLocked() }
            self.observeWorkspace()
            self.publish("Работает")
        }
    }

    func convertNow() {
        stateQueue.async { [weak self] in self?.beginConversionLocked() }
    }

    /// Called by the Services provider on its callback thread. It stays synchronous and AX-free.
    /// A service result is accepted only for the short pending request created by pressService.
    func convertServiceText(_ text: String) -> String? {
        guard isRunning, !IsSecureEventInputEnabled(), !text.isEmpty,
              text.utf16.count <= Self.maximumServiceUTF16Length,
              let request = serviceLock.withLock({ () -> PendingService? in
                  guard let pendingService, pendingService.deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds,
                        generationIsCurrent(pendingService.generation) else {
                      pendingService = nil
                      return nil
                  }
                  self.pendingService = nil
                  return pendingService
              }), generationIsCurrent(request.generation) else { return nil }
        let currentSourceID = InputSources.currentID()
        guard currentSourceID == request.sourceID,
              let conversion = LayoutConverter.convert(text, currentInputSourceID: currentSourceID),
              InputSources.isAvailable(id: conversion.targetInputSourceID),
              !IsSecureEventInputEnabled(), generationIsCurrent(request.generation) else { return nil }
        setExpectedSource(conversion.targetInputSourceID)
        guard InputSources.select(id: conversion.targetInputSourceID) else { clearExpectedSource(); return nil }
        clearPendingService()
        diagnose(request.context, route: "service", reason: "accepted")
        publish("Результат передан службе преобразования")
        return conversion.text
    }

    private func startOnMain() {
        guard !isRunning else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.PuntoSwitcher").isEmpty else {
            publish("Сначала завершите Punto Switcher, затем возобновите")
            return
        }
        guard AXIsProcessTrusted() else {
            publish("Требуется разрешение Универсального доступа")
            return
        }
        guard installTap() else {
            publish("Требуется разрешение Мониторинга ввода")
            return
        }
        advanceGeneration()
        setLifecycle(running: true, paused: false)
        stateQueue.async { self.running = true; self.paused = false; self.resetStateLocked() }
        observeWorkspace()
        // TIS keyboard-map construction is intentionally warmed outside the event tap callback.
        axQueue.async {
            _ = InputSources.text(for: TypedKey(keyCode: 0, shift: false, caps: false), sourceID: InputSources.abcID)
            _ = InputSources.text(for: TypedKey(keyCode: 0, shift: false, caps: false), sourceID: InputSources.russianWinID)
        }
        publish("Работает")
    }

    private func installTap() -> Bool {
        guard tap == nil else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        }
        let types: [CGEventType] = [
            .flagsChanged, .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: Self.eventTapCallback,
                                             userInfo: context),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = newTap
        tapSource = source
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    private func removeTap() {
        shortcutRecognizer.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let runtime = Unmanaged<SwitcherRuntime>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            runtime.cancelMutationAndReplayHeld()
            runtime.advanceGeneration()
            runtime.shortcutRecognizer.reset()
            runtime.stateQueue.async { [weak runtime] in runtime?.resetStateLocked() }
            DispatchQueue.main.async { [weak runtime] in
                guard let runtime, runtime.isRunning else { return }
                _ = runtime.installTap()
                runtime.publish("Монитор клавиатуры восстановлен")
            }
            return Unmanaged.passUnretained(event)
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if tag == ownEventTag { return Unmanaged.passUnretained(event) }
        if tag == replayEventTag {
            runtime.advanceGeneration()
            runtime.stateQueue.async { [weak runtime] in runtime?.resetStateLocked() }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, !runtime.isRunning {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if runtime.shortcutRecognizer.ownsKeyUp(for: keyCode) {
                _ = runtime.shortcutRecognizer.keyUp(keyCode: keyCode,
                                                      modifiers: SwitcherRuntime.shortcutModifiers(event.flags))
                return nil
            }
        }
        guard runtime.isRunning else { return Unmanaged.passUnretained(event) }
        guard !IsSecureEventInputEnabled() else {
            runtime.advanceGeneration()
            runtime.shortcutRecognizer.cancelGesture()
            if type == .keyUp {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if runtime.shortcutRecognizer.ownsKeyUp(for: keyCode) {
                    _ = runtime.shortcutRecognizer.keyUp(keyCode: keyCode,
                                                          modifiers: SwitcherRuntime.shortcutModifiers(event.flags))
                    return nil
                }
            }
            runtime.cancelMutationAndDiscardHeld()
            runtime.stateQueue.async { [weak runtime] in runtime?.resetStateLocked() }
            return Unmanaged.passUnretained(event)
        }
        if runtime.routeConcurrentEvent(type: type, event: event) { return nil }
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp
            || type == .otherMouseDown || type == .otherMouseUp || type == .scrollWheel {
            runtime.shortcutRecognizer.cancelGesture()
        }
        if runtime.shortcutRecording {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = SwitcherRuntime.shortcutModifiers(event.flags)
            if type == .keyDown {
                runtime.shortcutRecognizer.observeKeyDownWhileRecording(keyCode, modifiers: modifiers)
            } else if type == .keyUp {
                if runtime.shortcutRecognizer.observeKeyUpWhileRecording(keyCode, modifiers: modifiers) { return nil }
            } else if type == .flagsChanged {
                runtime.shortcutRecognizer.observeModifiersWhileRecording(modifiers)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = SwitcherRuntime.shortcutModifiers(event.flags)
            let unsupported = SwitcherRuntime.hasUnsupportedShortcutModifier(type: type, keyCode: keyCode, flags: event.flags)
            let result: ShortcutRecognitionResult
            switch type {
            case .keyDown:
                result = runtime.shortcutRecognizer.keyDown(
                    keyCode: keyCode, modifiers: modifiers, hasUnsupportedModifier: unsupported,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
            case .keyUp:
                result = runtime.shortcutRecognizer.keyUp(
                    keyCode: keyCode, modifiers: modifiers, hasUnsupportedModifier: unsupported
                )
            case .flagsChanged:
                result = runtime.shortcutRecognizer.modifiersChanged(
                    modifiers, hasUnsupportedModifier: unsupported
                )
            default:
                result = .passThrough
            }
            if result == .consume {
                if type == .keyDown { runtime.advanceGeneration() }
                return nil
            }
            if result == .trigger {
                let generation = runtime.advanceGeneration()
                runtime.stateQueue.async { [weak runtime] in
                    runtime?.beginConversionLocked(generation: generation)
                }
                if type == .keyUp { return nil }
                if type == .flagsChanged { return Unmanaged.passUnretained(event) }
            }
            if type == .flagsChanged {
                runtime.advanceGeneration()
                return Unmanaged.passUnretained(event)
            }
        }
        // Key-up is relevant only while holding a conversion batch; it must not invalidate a chord fired on key release.
        if type == .keyUp {
            if runtime.testShortcutEnabled {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                let isDiagnosticKey = keyCode == 111 || keyCode == 40
                let followsDiagnosticDown = runtime.diagnosticShortcutKeyCode == keyCode
                if isDiagnosticKey && (followsDiagnosticDown || flags.contains([.maskControl, .maskAlternate, .maskCommand])) {
                    SwitcherRuntime.statusLogger.notice("diagnostic keyup code=\(keyCode) flags=\(flags.rawValue)")
                }
                if followsDiagnosticDown { runtime.diagnosticShortcutKeyCode = nil }
                if keyCode == 111 || keyCode == 40 {
                    let generation = runtime.currentGeneration()
                    runtime.stateQueue.async { [weak runtime] in
                        runtime?.handle(type: .keyUp, keyCode: keyCode, flags: flags, sourceID: nil,
                                        payloadValid: true, generation: generation)
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        let generation = runtime.advanceGeneration()
        if type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .rightMouseDown
            || type == .otherMouseDown || type == .scrollWheel {
            let keyCode = type == .keyDown || type == .flagsChanged
                ? UInt16(event.getIntegerValueField(.keyboardEventKeycode)) : 0
            let flags = event.flags
            // The tap runs on main; snapshot TIS here so queued key handling cannot observe a later layout.
            let sourceID = type == .keyDown ? InputSources.currentID() : nil
            if runtime.testShortcutEnabled, type == .keyDown, (keyCode == 111 || keyCode == 40),
               flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
                runtime.diagnosticShortcutKeyCode = keyCode
                SwitcherRuntime.statusLogger.notice("diagnostic keydown code=\(keyCode) flags=\(flags.rawValue)")
            }
            let payloadValid = type != .keyDown || runtime.keyPayloadMatches(
                event, keyCode: keyCode, flags: flags, sourceID: sourceID)
            runtime.stateQueue.async { [weak runtime] in
                runtime?.handle(type: type, keyCode: keyCode, flags: flags, sourceID: sourceID,
                                payloadValid: payloadValid, generation: generation)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Retain real input during the short destructive batch so clicks and navigation cannot split deletion.
    /// The exact copied event stream is replayed in order after replacement.
    private func routeConcurrentEvent(type: CGEventType, event: CGEvent) -> Bool {
        var replay: [HeldEvent] = []
        let swallowed = mutationLock.withLock { () -> Bool in
            guard mutationActive else { return false }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- mutationStartedAt
            let isInput = type == .keyDown || type == .keyUp || type == .flagsChanged
                || type == .leftMouseDown || type == .leftMouseUp
                || type == .rightMouseDown || type == .rightMouseUp
                || type == .otherMouseDown || type == .otherMouseUp || type == .scrollWheel
            guard isInput, elapsed < mutationHoldBudgetNanoseconds,
                  heldEvents.count < Self.maximumHeldEvents, let copy = event.copy() else {
                mutationCancelled = true
                mutationActive = false
                replay = heldEvents
                heldEvents.removeAll(keepingCapacity: true)
                return false
            }
            heldEvents.append(HeldEvent(event: copy, type: type))
            return true
        }
        if !replay.isEmpty { postReplay(replay) }
        return swallowed
    }

    private func beginMutation(context: FocusContext, clipboardMode: Bool = false) -> Bool {
        mutationLock.withLock {
            guard !mutationCancelled else { return false }
            mutationActive = true
            mutationStartedAt = DispatchTime.now().uptimeNanoseconds
            mutationHoldBudgetNanoseconds = clipboardMode
                ? Self.maximumClipboardHoldNanoseconds : Self.maximumHoldNanoseconds
            mutationContext = context
            heldEvents.removeAll(keepingCapacity: true)
            return true
        }
    }

    private func finishMutation() {
        let snapshot = mutationLock.withLock { () -> ([HeldEvent], FocusContext?) in
            let events = heldEvents
            heldEvents.removeAll(keepingCapacity: true)
            return (events, mutationContext)
        }
        guard !snapshot.0.isEmpty else { postReplayAndDeactivate([]); return }
        guard let context = snapshot.1, SelectionAccess.matches(context), !IsSecureEventInputEnabled() else {
            diagnose(context: snapshot.1, route: "held-input", reason: "focus-changed-events-discarded")
            discardHeldAndDeactivate()
            return
        }
        postReplayAndDeactivate(snapshot.0)
    }

    private func cancelMutationAndReplayHeld() {
        let replay = mutationLock.withLock { () -> [HeldEvent] in
            mutationCancelled = true
            let events = heldEvents
            heldEvents.removeAll(keepingCapacity: true)
            return events
        }
        postReplayAndDeactivate(replay)
    }

    private func cancelMutationAndDiscardHeld() {
        mutationLock.withLock {
            mutationCancelled = true
            mutationActive = false
            heldEvents.removeAll(keepingCapacity: true)
            mutationContext = nil
        }
    }

    private func discardHeldAndDeactivate() {
        let finish = {
            self.mutationLock.withLock {
                self.heldEvents.removeAll(keepingCapacity: true)
                self.mutationContext = nil
                self.mutationActive = false
            }
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.sync(execute: finish) }
    }

    private func postReplayAndDeactivate(_ events: [HeldEvent]) {
        let finish = {
            // AX validation may have taken time after the first snapshot. Drain events
            // collected in that interval too, atomically with ending capture on main.
            let tail = self.mutationLock.withLock { () -> [HeldEvent] in
                let tail = self.heldEvents
                self.heldEvents.removeAll(keepingCapacity: true)
                return tail
            }
            self.postReplay(events + tail)
            self.mutationLock.withLock {
                self.mutationContext = nil
                self.mutationActive = false
            }
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.sync(execute: finish) }
    }

    private func postReplay(_ events: [HeldEvent]) {
        let post = {
            for held in events {
                held.event.setIntegerValueField(.eventSourceUserData, value: Self.replayEventTag)
                held.event.post(tap: .cghidEventTap)
            }
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.sync(execute: post) }
    }

    private func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, sourceID: String?,
                        payloadValid: Bool, generation: UInt64) {
        guard running, !paused else { resetStateLocked(); return }
        switch type {
        case .flagsChanged:
            break
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            clearPendingService()
            resetStateLocked()
        case .keyDown:
            let option = flags.contains(.maskAlternate)
            let command = flags.contains(.maskCommand)
            let control = flags.contains(.maskControl)
            let fn = flags.contains(.maskSecondaryFn)
            let testShortcutKey = testShortcutEnabled && (keyCode == 111 || keyCode == 40) && option && command && control
                && !flags.contains(.maskShift)
            guard payloadValid || testShortcutKey else {
                resetBuffer()
                testShortcutArmed = false
                testShortcutF12Released = false
                return
            }
            if testShortcutKey {
                testShortcutArmed = true
                testShortcutF12Released = false
                return
            }
            if testShortcutArmed {
                testShortcutArmed = false
                testShortcutF12Released = false
            }
            if option || command || control || fn {
                resetStateLocked()
                return
            }
            if [36, 48, 53, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(keyCode) {
                resetStateLocked()
                return
            }
            if keyCode == 51 {
                if flags.contains(.maskShift) { resetBuffer() } else { buffer.backspace() }
                if buffer.keys.isEmpty { bufferSourceID = nil }
                return
            }
            guard let sourceID,
                  sourceID == InputSources.abcID || sourceID == InputSources.russianWinID else {
                resetBuffer()
                return
            }
            if let bufferSourceID, bufferSourceID != sourceID { resetBuffer() }
            bufferSourceID = sourceID
            buffer.append(TypedKey(keyCode: keyCode,
                                   shift: flags.contains(.maskShift),
                                   caps: flags.contains(.maskAlphaShift)))
        case .keyUp where (keyCode == 111 || keyCode == 40) && testShortcutArmed:
            testShortcutF12Released = true
            stateQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self, self.testShortcutArmed, self.testShortcutF12Released else { return }
                self.testShortcutArmed = false
                self.testShortcutF12Released = false
                self.beginConversionLocked(generation: self.currentGeneration())
            }
        default:
            break
        }
    }

    /// Reject Unicode-injected strings and IME/multi-character events while retaining ordinary physical keys.
    private func keyPayloadMatches(_ event: CGEvent, keyCode: UInt16, flags: CGEventFlags, sourceID: String?) -> Bool {
        // Editing/navigation keys carry control Unicode, not a printable layout character.
        // They must reach handle() so Backspace updates the buffer rather than losing it.
        if [36, 48, 51, 53, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(keyCode) {
            return true
        }
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return true }
        guard length <= 2, let sourceID else { return false }
        let received = String(utf16CodeUnits: units, count: length)
        guard received.count == 1 else { return false }
        let key = TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        return InputSources.text(for: key, sourceID: sourceID) == received
    }

    private static func shortcutModifiers(_ flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    private static let functionAndNavigationKeyCodes: Set<UInt16> = [
        // F1–F20: NSEvent's .function flag can accompany these ordinary key-downs.
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        // Home, Page Up, forward Delete, End, Page Down, and arrows.
        115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    private static func hasUnsupportedShortcutModifier(type: CGEventType, keyCode: UInt16,
                                                        flags: CGEventFlags) -> Bool {
        if flags.contains(.maskHelp) { return true }
        guard flags.contains(.maskSecondaryFn) else { return false }
        // flagsChanged reports physical Fn separately; on key-down/up this flag is also
        // attached to F/navigation keys and must not invalidate those configurable shortcuts.
        if type == .flagsChanged { return true }
        return !functionAndNavigationKeyCodes.contains(keyCode)
    }

    /// Opt-in live-integration route: `--test-shortcut` maps Control+Option+Command+F12 to convertNow.
    /// It is disabled by default and does not create a testing or automation mode.
    private var testShortcutEnabled: Bool { CommandLine.arguments.contains("--test-shortcut") }

    private func beginConversionLocked(generation: UInt64? = nil) {
        guard running, !paused, !conversionBusy, !IsSecureEventInputEnabled() else {
            resetStateLocked()
            return
        }
        let serviceInFlight = serviceLock.withLock { () -> Bool in
            guard let request = pendingService else { return false }
            if request.deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds { return true }
            pendingService = nil
            return false
        }
        guard !serviceInFlight else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.PuntoSwitcher").isEmpty else {
            resetStateLocked()
            publish("Сначала завершите Punto Switcher, затем возобновите")
            return
        }
        conversionBusy = true
        let expectedGeneration = generation ?? currentGeneration()
        let keys = buffer.keys
        let sourceID = bufferSourceID
        buffer.reset()
        bufferSourceID = nil
        mutationLock.withLock { mutationCancelled = false }
        axQueue.async { [weak self] in
            guard let self else { return }
            self.convert(keys: keys, sourceID: sourceID, generation: expectedGeneration)
            self.stateQueue.async { self.conversionBusy = false }
        }
    }

    private func convert(keys: [TypedKey], sourceID: String?, generation: UInt64) {
        guard conversionContextIsCurrent(generation) else { return }
        let probe = SelectionAccess.probe()
        let probeDetails = SelectionAccess.diagnosticSnapshot()
        Self.statusLogger.notice("route=probe details=\(probeDetails, privacy: .public)")
        switch probe {
        case .protected(let reason, let context):
            diagnoseGesture(context: context, kind: "protected-\(reason)", keys: keys, sourceID: sourceID)
            publish("Защищённое поле или ввод: действие пропущено")
        case .selected(let selected, let context):
            diagnoseGesture(context: context, kind: "selected", keys: keys, sourceID: sourceID)
            guard !IsSecureEventInputEnabled(), SelectionAccess.matches(context) else {
                diagnose(context, route: "selection", reason: "focus-or-security-changed")
                return
            }
            guard let conversion = LayoutConverter.convert(selected, currentInputSourceID: InputSources.currentID()) else {
                diagnose(context, route: "selection", reason: "no-convertible-characters")
                publish("Нет букв, доступных для переключения раскладки")
                return
            }
            replaceSelection(selected, conversion: conversion, context: context, generation: generation)
        case .none(let context):
            diagnoseGesture(context: context, kind: "none", keys: keys, sourceID: sourceID)
            convertRecentWord(keys: keys, sourceID: sourceID, context: context, generation: generation)
        case .unavailable(let reason, let context):
            diagnoseGesture(context: context, kind: "unavailable-\(reason)", keys: keys, sourceID: sourceID)
            if !keys.isEmpty {
                convertRecentWord(keys: keys, sourceID: sourceID, context: context, generation: generation)
            } else {
                // With no fresh physical word, try the focused app's exact Services item.
                _ = requestSelectionService(context, generation: generation)
            }
        case .noFocus(let reason):
            diagnoseGesture(context: nil, kind: "no-focus-\(reason)", keys: keys, sourceID: sourceID)
            publish("Нет активного поля для переключения раскладки")
        }
    }

    private func convertRecentWord(keys: [TypedKey], sourceID: String?, context: FocusContext, generation: UInt64) {
        guard !keys.isEmpty else {
            diagnose(context, route: "recent-word", reason: "no-captured-keys")
            return
        }
        guard let sourceID else {
            diagnose(context, route: "recent-word", reason: "source-id-unavailable")
            return
        }
        guard let original = reconstruct(keys, sourceID: sourceID), !original.isEmpty else {
            diagnose(context, route: "recent-word", reason: "key-reconstruction-failed")
            return
        }
        guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation) else {
            diagnose(context, route: "recent-word", reason: "focus-or-generation-changed")
            return
        }
        guard let conversion = LayoutConverter.convert(original, currentInputSourceID: sourceID) else {
            diagnose(context, route: "recent-word", reason: "no-convertible-characters")
            publish("Нет букв, доступных для переключения раскладки")
            return
        }
        replaceRecentWord(keys, original: original, conversion: conversion, context: context,
                          generation: generation)
    }

    private func diagnoseGesture(context: FocusContext?, kind: String, keys: [TypedKey], sourceID: String?) {
        let pid = context?.pid ?? 0
        let bundleID = context.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier } ?? "unknown"
        let source = sourceID ?? "unknown"
        Self.statusLogger.notice("route=gesture pid=\(pid) bundleID=\(bundleID, privacy: .public) reason=probe-\(kind, privacy: .public) keyCount=\(keys.count) sourceID=\(source, privacy: .public)")
    }

    private func reconstruct(_ keys: [TypedKey], sourceID: String) -> String? {
        var text = ""
        for key in keys {
            guard let part = InputSources.text(for: key, sourceID: sourceID) else { return nil }
            text.append(part)
        }
        return text
    }

    private func replaceSelection(_ original: String, conversion: LayoutConversion,
                                  context: FocusContext, generation: UInt64) {
        let expectedState = expectedSelectionValue(context: context, original: original, replacement: conversion.text)
        let expectedValue: String?
        let originalValue: String?
        if case .expected(let original, let replacement) = expectedState {
            expectedValue = replacement
            originalValue = original
        } else {
            expectedValue = nil
            originalValue = nil
        }
        guard InputSources.isAvailable(id: conversion.targetInputSourceID) else {
            diagnose(context, route: "selection", reason: "unsupported-size-or-target-layout")
            return
        }
        guard !IsSecureEventInputEnabled(), SelectionAccess.matches(context), generationIsCurrent(generation) else {
            diagnose(context, route: "selection", reason: "focus-or-generation-changed")
            return
        }
        guard let element = context.element else { return }
        var textSettable = DarwinBoolean(false)
        let canSetText = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success
            && textSettable.boolValue
        let useClipboard = isCodex(context)
        if conversion.text.utf16.count > Self.maximumSyntheticUTF16Length && !useClipboard {
            // Prefer the app's Services route for long text; fall back to AX only when its range/value snapshot was compatible.
            if requestSelectionService(context, generation: generation) { return }
            if canSetText,
               expectedValue != nil,
               SelectionAccess.matches(context), generationIsCurrent(generation), !IsSecureEventInputEnabled(),
               (copyAttribute(element, kAXSelectedTextAttribute) as? String) == original {
                let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, conversion.text as CFString)
                guard result == .success else {
                    diagnose(context, route: "selection-ax", reason: "verified-large-set-failed")
                    publish("Не удалось заменить большое выделение")
                    return
                }
                guard selectAndWaitForLayout(conversion.targetInputSourceID, context: context, generation: generation) else {
                    diagnose(context, route: "selection-ax", reason: "text-set-but-layout-not-confirmed")
                    publish("Текст изменён, но раскладка не переключилась")
                    return
                }
                reportDispatch(context, route: "selection-ax", expectedValue: expectedValue,
                               originalValue: originalValue)
                return
            }
            diagnose(context, route: "selection", reason: "oversize-without-service-or-compatible-ax-setter")
            publish("Выделение слишком большое для безопасной замены")
            return
        }
        guard selectAndWaitForLayout(conversion.targetInputSourceID, context: context, generation: generation) else {
            diagnose(context, route: "selection", reason: "target-layout-not-confirmed")
            return
        }
        guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation),
              (copyAttribute(element, kAXSelectedTextAttribute) as? String) == original else {
            diagnose(context, route: "selection", reason: "selection-changed-before-replacement")
            return
        }
        guard useClipboard || conversion.text.utf16.count <= Self.maximumSyntheticUTF16Length else { return }
        let preparedEvents: [PreparedKeyEvent]
        if useClipboard {
            guard let pasteEvent = makePasteEvent() else {
                diagnose(context, route: "selection", reason: "paste-event-preparation-failed")
                return
            }
            preparedEvents = [pasteEvent]
        } else if let events = prepareRecentWordEvents(deleteCount: 0, replacement: conversion.text,
                                                       sourceID: conversion.targetInputSourceID) {
            preparedEvents = events
        } else {
            diagnose(context, route: "selection", reason: "event-preparation-failed")
            return
        }
        guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation),
              (copyAttribute(element, kAXSelectedTextAttribute) as? String) == original else {
            diagnose(context, route: "selection", reason: "selection-changed-before-replacement")
            return
        }
        guard beginMutation(context: context, clipboardMode: useClipboard) else {
            diagnose(context, route: "selection", reason: "mutation-already-cancelled")
            return
        }
        var clipboardReplacement: ClipboardReplacement?
        var clipboardResolved = false
        var clipboardRestoreSucceeded = true
        var pasteDispatched = false
        defer {
            if let clipboardReplacement, !clipboardResolved {
                clipboardRestoreSucceeded = pasteDispatched
                    ? clipboardReplacement.finish(confirmed: false)
                    : clipboardReplacement.cancelBeforeDispatch()
                clipboardResolved = true
            } else if useClipboard && clipboardReplacement == nil {
                clipboardRestoreSucceeded = ClipboardReplacement.isReadyForInputReplay()
            }
            if clipboardRestoreSucceeded { finishMutation() }
            else {
                reportClipboardRestoreFailure(context: context, route: "selection-keys")
                discardHeldAndDeactivate()
            }
        }
        if useClipboard {
            guard let replacement = ClipboardReplacement.prepare(text: conversion.text) else {
                diagnose(context, route: "selection", reason: "clipboard-prepare-failed")
                return
            }
            clipboardReplacement = replacement
            guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation),
                  (copyAttribute(element, kAXSelectedTextAttribute) as? String) == original else {
                diagnose(context, route: "selection", reason: "selection-changed-before-paste")
                return
            }
            guard replacement.isPreparedReplacementCurrent() else {
                diagnose(context, route: "selection", reason: "clipboard-changed-before-paste")
                return
            }
        }
        for (index, pair) in preparedEvents.enumerated() {
            guard !IsSecureEventInputEnabled(), generationIsCurrent(generation), !mutationWasCancelled,
                  (index.isMultiple(of: 32) ? SelectionAccess.matches(context) : true) else {
                diagnose(context, route: "selection-keys", reason: "synthetic-dispatch-aborted")
                publish("Замена прервана — проверьте текст в редакторе")
                return
            }
            if useClipboard, clipboardReplacement?.isPreparedReplacementCurrent() != true {
                diagnose(context, route: "selection-keys", reason: "clipboard-changed-before-paste")
                return
            }
            postPreparedKeyEvents(pair)
            if useClipboard { pasteDispatched = true }
        }
        guard !mutationWasCancelled, generationIsCurrent(generation) else {
            diagnose(context, route: "selection-keys", reason: "synthetic-dispatch-aborted")
            publish("Замена прервана — проверьте текст в редакторе")
            return
        }
        let confirmed = reportDispatch(context, route: useClipboard ? "selection-paste" : "selection-keys",
                                       expectedValue: expectedValue,
                                       originalValue: originalValue)
        if let clipboardReplacement {
            clipboardRestoreSucceeded = clipboardReplacement.finish(confirmed: confirmed)
        }
        clipboardResolved = clipboardReplacement != nil
    }

    private func replaceRecentWord(_ keys: [TypedKey], original: String, conversion: LayoutConversion,
                                   context: FocusContext, generation: UInt64) {
        guard !keys.isEmpty, keys.count <= Self.maximumPhysicalReplacementKeys,
              conversion.text.utf16.count <= Self.maximumSyntheticUTF16Length,
              InputSources.isAvailable(id: conversion.targetInputSourceID),
              SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation) else {
            diagnose(context, route: "recent-word", reason: "focus-size-or-layout-check-failed")
            return
        }
        let axState = recentWordAXState(in: context, original: original)
        if case .selectionActive = axState {
            diagnose(context, route: "recent-word", reason: "selection-active-before-delete")
            return
        }
        let expectedValue: String?
        let originalValue: String?
        if case let .verified(value, range) = axState {
            originalValue = value
            expectedValue = (value as NSString).replacingCharacters(
                in: NSRange(location: range.location, length: range.length), with: conversion.text)
        } else {
            originalValue = nil
            expectedValue = nil
        }
        let useClipboard = isCodex(context)
        guard selectAndWaitForLayout(conversion.targetInputSourceID, context: context, generation: generation),
              SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation) else {
            diagnose(context, route: "recent-word", reason: "target-layout-or-focus-not-confirmed")
            return
        }
        guard var preparedEvents = prepareRecentWordEvents(deleteCount: keys.count,
                                                           replacement: useClipboard ? "" : conversion.text,
                                                           sourceID: conversion.targetInputSourceID) else {
            diagnose(context, route: "recent-word-keys", reason: "event-preparation-failed")
            return
        }
        if useClipboard {
            guard let pasteEvent = makePasteEvent() else {
                diagnose(context, route: "recent-word-keys", reason: "paste-event-preparation-failed")
                return
            }
            preparedEvents.append(pasteEvent)
        }
        let estimatedDispatchNanos = UInt64(preparedEvents.count) * 3_000_000
        let dispatchBudget = useClipboard
            ? Self.maximumClipboardHoldNanoseconds - Self.maximumClipboardFinishNanoseconds
                - Self.maximumReadbackNanoseconds - Self.clipboardSafetyMarginNanoseconds
            : Self.maximumHoldNanoseconds - Self.mutationSafetyMarginNanoseconds
        guard estimatedDispatchNanos < dispatchBudget else {
            diagnose(context, route: "recent-word-keys", reason: "transaction-exceeds-safe-time-bound")
            return
        }
        diagnose(context, route: "recent-word-keys", reason: "events-prepared")
        let beforeDeleteAXState = recentWordAXState(in: context, original: original)
        if case .selectionActive = beforeDeleteAXState {
            diagnose(context, route: "recent-word-keys", reason: "selection-active-before-delete")
            return
        }
        guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation) else {
            diagnose(context, route: "recent-word-keys", reason: "focus-or-generation-changed-before-delete")
            return
        }
        guard beginMutation(context: context, clipboardMode: useClipboard) else {
            diagnose(context, route: "recent-word-keys", reason: "mutation-already-cancelled")
            return
        }
        var clipboardReplacement: ClipboardReplacement?
        var clipboardResolved = false
        var clipboardRestoreSucceeded = true
        var pasteDispatched = false
        defer {
            if let clipboardReplacement, !clipboardResolved {
                clipboardRestoreSucceeded = pasteDispatched
                    ? clipboardReplacement.finish(confirmed: false)
                    : clipboardReplacement.cancelBeforeDispatch()
                clipboardResolved = true
            } else if useClipboard && clipboardReplacement == nil {
                clipboardRestoreSucceeded = ClipboardReplacement.isReadyForInputReplay()
            }
            if clipboardRestoreSucceeded { finishMutation() }
            else {
                reportClipboardRestoreFailure(context: context, route: "recent-word-keys")
                discardHeldAndDeactivate()
            }
        }
        if useClipboard {
            guard let replacement = ClipboardReplacement.prepare(text: conversion.text) else {
                diagnose(context, route: "recent-word-keys", reason: "clipboard-prepare-failed")
                return
            }
            clipboardReplacement = replacement
            let beforePasteAXState = recentWordAXState(in: context, original: original)
            if case .selectionActive = beforePasteAXState {
                diagnose(context, route: "recent-word-keys", reason: "selection-active-before-delete")
                return
            }
            guard SelectionAccess.matches(context), !IsSecureEventInputEnabled(), generationIsCurrent(generation) else {
                diagnose(context, route: "recent-word-keys", reason: "focus-or-generation-changed-before-delete")
                return
            }
        }
        diagnose(context, route: "recent-word-keys", reason: "deletion-started")
        var insertionStarted = false
        for (index, pair) in preparedEvents.enumerated() {
            if useClipboard, index == 0,
               clipboardReplacement?.isPreparedReplacementCurrent() != true {
                diagnose(context, route: "recent-word-keys", reason: "clipboard-changed-before-delete")
                return
            }
            guard !IsSecureEventInputEnabled(), generationIsCurrent(generation), !mutationWasCancelled else {
                diagnose(context, route: "recent-word-keys", reason: index < keys.count ? "aborted-during-delete" : "aborted-during-insert")
                publish("Замена прервана — проверьте текст в редакторе")
                return
            }
            if index == keys.count {
                diagnose(context, route: "recent-word-keys", reason: "insertion-started")
                insertionStarted = true
            }
            if index.isMultiple(of: 32), index > 0, !SelectionAccess.matches(context) {
                diagnose(context, route: "recent-word-keys", reason: "focus-changed-during-mutation")
                publish("Замена прервана — проверьте текст в редакторе")
                return
            }
            if useClipboard, index == keys.count,
               clipboardReplacement?.isPreparedReplacementCurrent() != true {
                diagnose(context, route: "recent-word-keys", reason: "clipboard-changed-before-paste")
                publish("Текст удалён частично; буфер обмена изменился до вставки")
                return
            }
            postPreparedKeyEvents(pair)
            if useClipboard && index == keys.count { pasteDispatched = true }
        }
        if !insertionStarted {
            diagnose(context, route: "recent-word-keys", reason: "insertion-started")
        }
        diagnose(context, route: "recent-word-keys", reason: "injection-sent")
        let confirmed = reportDispatch(context, route: useClipboard ? "recent-word-paste" : "recent-word-keys",
                                       expectedValue: expectedValue,
                                       originalValue: originalValue)
        if let clipboardReplacement {
            clipboardRestoreSucceeded = clipboardReplacement.finish(confirmed: confirmed)
        }
        clipboardResolved = clipboardReplacement != nil
    }

    private func recentWordAXState(in context: FocusContext, original: String) -> RecentWordAXState {
        guard let element = context.element else { return .unavailable }
        let selectedResult = queryAttribute(element, kAXSelectedTextAttribute as CFString)
        if selectedResult.error == .success, let selected = selectedResult.value as? String,
           !selected.isEmpty {
            return .selectionActive
        }
        let caretResult = queryAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        var caret = CFRange(location: 0, length: 0)
        guard caretResult.error == .success, let caretValue = caretResult.value,
              CFGetTypeID(caretValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(caretValue, to: AXValue.self), .cfRange, &caret),
              caret.location >= 0, caret.length >= 0 else { return .unavailable }
        if caret.length > 0 { return .selectionActive }
        let valueResult = queryAttribute(element, kAXValueAttribute as CFString)
        guard valueResult.error == .success, let value = valueResult.value as? String else { return .unavailable }
        let utf16Length = (value as NSString).length
        guard caret.location <= utf16Length, caret.length <= utf16Length - caret.location,
              caret.length == 0 else { return .unavailable }
        guard let range = ReplacementPlanner.recentWordRange(in: value, caretUTF16: caret.location, recentText: original) else {
            return .unavailable
        }
        return .verified(value: value, range: CFRange(location: range.location, length: range.length))
    }

    private func expectedSelectionValue(context: FocusContext, original: String, replacement: String) -> ExpectedValueState {
        guard let element = context.element else { return .unavailable }
        let valueResult = queryAttribute(element, kAXValueAttribute as CFString)
        let rangeResult = queryAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard valueResult.error == .success, rangeResult.error == .success,
              let value = valueResult.value as? String,
              let rangeValue = rangeResult.value, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unavailable }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length > 0 else { return .mismatch }
        let nsValue = value as NSString
        guard range.location <= nsValue.length, range.length <= nsValue.length - range.location,
              nsValue.substring(with: NSRange(location: range.location, length: range.length)) == original else { return .mismatch }
        return .expected(original: value,
                         replacement: nsValue.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement))
    }

    private func reportDispatch(_ context: FocusContext, route: String, expectedValue: String?,
                                originalValue: String? = nil) -> Bool {
        guard let expectedValue else {
            diagnose(context, route: route, reason: "dispatched-ax-readback-unavailable")
            publish("Текст отправлен; значение AX недоступно для проверки")
            return false
        }
        var sawOriginal = false
        var sawOther = false
        var sawReadableValue = false
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.maximumReadbackNanoseconds
        for attempt in 0..<10 {
            guard SelectionAccess.matches(context), !IsSecureEventInputEnabled() else {
                diagnose(context, route: route, reason: "focus-changed-before-readback")
                publish("Текст отправлен; фокус изменился до проверки")
                return false
            }
            if let element = context.element,
               let value = copyAttribute(element, kAXValueAttribute) as? String {
                sawReadableValue = true
                if value == expectedValue {
                    diagnose(context, route: route, reason: "readback-confirmed")
                    publish("Текст переключён")
                    return true
                }
                if value == originalValue { sawOriginal = true }
                else { sawOther = true }
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.02) }
        }
        let reason = sawOther ? "readback-unexpected-value"
            : (sawOriginal ? "readback-original-unchanged"
               : (sawReadableValue ? "readback-other-unmatched" : "readback-unavailable"))
        diagnose(context, route: route, reason: reason)
        publish("Не удалось подтвердить замену — проверьте текст")
        return false
    }

    private func diagnose(_ context: FocusContext, route: String, reason: String) {
        let bundleID = NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier ?? "unknown"
        Self.statusLogger.notice("route=\(route, privacy: .public) pid=\(context.pid) bundleID=\(bundleID, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func reportClipboardRestoreFailure(context: FocusContext, route: String) {
        diagnose(context, route: route, reason: "clipboard-restore-failed-held-input-discarded")
        publish("Не удалось восстановить исходный буфер обмена; отложенные действия отброшены")
    }

    private func diagnose(context: FocusContext?, route: String, reason: String) {
        if let context { diagnose(context, route: route, reason: reason) }
        else { Self.statusLogger.notice("route=\(route, privacy: .public) pid=0 bundleID=unknown reason=\(reason, privacy: .public)") }
    }

    @discardableResult
    private func requestSelectionService(_ context: FocusContext, generation: UInt64) -> Bool {
        guard generationIsCurrent(generation), SelectionAccess.matches(context), !IsSecureEventInputEnabled() else { return false }
        let pending = PendingService(context: context, generation: generation,
                                     deadline: DispatchTime.now() + .milliseconds(1_500),
                                     sourceID: InputSources.currentID())
        serviceLock.withLock { pendingService = pending }
        guard SelectionAccess.pressService(in: context) else {
            serviceLock.withLock { pendingService = nil }
            diagnose(context, route: "selection-service", reason: "service-unavailable-or-press-failed")
            return false
        }
        diagnose(context, route: "selection-service", reason: "service-pressed-awaiting-callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_520)) { [weak self] in
            guard let self else { return }
            let timedOut = self.serviceLock.withLock { () -> Bool in
                guard self.pendingService?.generation == generation else { return false }
                self.pendingService = nil
                return true
            }
            if timedOut {
                self.diagnose(context, route: "selection-service", reason: "service-callback-timeout")
                self.publish("Служба не вернула результат выделения")
            }
        }
        return true
    }

    private func selectAndWaitForLayout(_ sourceID: String, context: FocusContext, generation: UInt64) -> Bool {
        guard conversionContextIsCurrent(generation), SelectionAccess.matches(context),
              setExpectedSource(sourceID), InputSources.select(id: sourceID) else { clearExpectedSource(); return false }
        for _ in 0..<25 {
            if IsSecureEventInputEnabled() || !generationIsCurrent(generation) || !SelectionAccess.matches(context) { return false }
            if InputSources.currentID() == sourceID {
                Thread.sleep(forTimeInterval: 0.015)
                return !IsSecureEventInputEnabled() && generationIsCurrent(generation)
                    && SelectionAccess.matches(context) && InputSources.currentID() == sourceID
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    @discardableResult
    private func setExpectedSource(_ sourceID: String) -> Bool {
        serviceLock.withLock {
            expectedSourceID = sourceID
            expectedSourceDeadline = DispatchTime.now() + .seconds(2)
            return true
        }
    }

    private func clearExpectedSource() {
        serviceLock.withLock { expectedSourceID = nil }
    }

    private func synthesize(_ text: String, sourceID: String, context: FocusContext, generation: UInt64) -> Bool {
        guard text.utf16.count <= Self.maximumSyntheticUTF16Length,
              SelectionAccess.matches(context), generationIsCurrent(generation), !IsSecureEventInputEnabled() else { return false }
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 128), index > 0,
               (!SelectionAccess.matches(context) || !generationIsCurrent(generation)
                || IsSecureEventInputEnabled() || mutationWasCancelled) { return false }
            if character == "\n" || character == "\r" || character == "\r\n" {
                guard postKey(keyCode: 36, flags: .maskShift, unicode: nil) else { return false }
            } else if let key = InputSources.key(for: character, sourceID: sourceID) {
                var flags: CGEventFlags = []
                if key.shift { flags.insert(.maskShift) }
                if key.caps { flags.insert(.maskAlphaShift) }
                guard postKey(keyCode: key.keyCode, flags: flags, unicode: String(character)) else { return false }
            } else {
                guard postKey(keyCode: 0, flags: [], unicode: String(character)) else { return false }
            }
        }
        return !mutationWasCancelled && generationIsCurrent(generation)
    }

    private func postKey(keyCode: UInt16, flags: CGEventFlags, unicode: String?) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let pair = makeKeyEvents(source: source, keyCode: keyCode, flags: flags, unicode: unicode) else { return false }
        postPreparedKeyEvents(pair)
        return true
    }

    private func postPreparedKeyEvents(_ pair: PreparedKeyEvent) {
        pair.down.post(tap: .cghidEventTap)
        usleep(1_500)
        pair.up.post(tap: .cghidEventTap)
        usleep(1_500)
    }

    private func prepareRecentWordEvents(deleteCount: Int, replacement: String, sourceID: String) -> [PreparedKeyEvent]? {
        guard deleteCount >= 0, deleteCount <= Self.maximumPhysicalReplacementKeys,
              replacement.utf16.count <= Self.maximumSyntheticUTF16Length,
              let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [PreparedKeyEvent] = []
        events.reserveCapacity(deleteCount + replacement.count)
        for _ in 0..<deleteCount {
            guard let pair = makeKeyEvents(source: source, keyCode: 51, flags: [], unicode: nil) else { return nil }
            events.append(pair)
        }
        for character in replacement {
            if character == "\n" || character == "\r" || character == "\r\n" {
                guard let pair = makeKeyEvents(source: source, keyCode: 36, flags: .maskShift, unicode: nil) else { return nil }
                events.append(pair)
            } else if let key = InputSources.key(for: character, sourceID: sourceID) {
                var flags: CGEventFlags = []
                if key.shift { flags.insert(.maskShift) }
                if key.caps { flags.insert(.maskAlphaShift) }
                guard let pair = makeKeyEvents(source: source, keyCode: key.keyCode,
                                               flags: flags, unicode: String(character)) else { return nil }
                events.append(pair)
            } else {
                guard let pair = makeKeyEvents(source: source, keyCode: 0, flags: [],
                                               unicode: String(character)) else { return nil }
                events.append(pair)
            }
        }
        return events
    }

    private func makePasteEvent() -> PreparedKeyEvent? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        return makeKeyEvents(source: source, keyCode: 9, flags: .maskCommand, unicode: nil)
    }

    private func isCodex(_ context: FocusContext) -> Bool {
        NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier == "com.openai.codex"
    }

    private func makeKeyEvents(source: CGEventSource, keyCode: UInt16, flags: CGEventFlags,
                               unicode: String?) -> PreparedKeyEvent? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        if let unicode {
            var units = Array(unicode.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        down.setIntegerValueField(.eventSourceUserData, value: Self.ownEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.ownEventTag)
        return PreparedKeyEvent(down: down, up: up)
    }

    private var mutationWasCancelled: Bool { mutationLock.withLock { mutationCancelled } }

    private func conversionContextIsCurrent(_ generation: UInt64) -> Bool {
        isRunning && generationIsCurrent(generation) && !IsSecureEventInputEnabled()
    }

    private func clearPendingService() { serviceLock.withLock { pendingService = nil } }

    private func queryAttribute(_ element: AXUIElement, _ name: CFString) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return (value, error)
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let result = queryAttribute(element, name as CFString)
        return result.error == .success ? result.value : nil
    }

    private func observeWorkspace() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.shortcutRecognizer.cancelGesture()
            self.cancelMutationAndDiscardHeld()
            self.advanceGeneration()
            self.clearPendingService()
            self.stateQueue.async { self.resetStateLocked() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.shortcutRecognizer.cancelGesture()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) } else { _ = self.installTap() }
            self.invalidateBuffer()
        })
        distributedTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.shortcutRecognizer.cancelGesture()
                let currentID = InputSources.currentID()
                let wasExpected = self.serviceLock.withLock { () -> Bool in
                    guard let expected = self.expectedSourceID else { return false }
                    let isExpected = currentID == expected && self.expectedSourceDeadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds
                    if !isExpected { self.expectedSourceID = nil }
                    return isExpected
                }
                if wasExpected { return }
                self.clearPendingService()
                self.stateQueue.async { self.resetBuffer() }
            })
    }

    private func removeWorkspaceObservers() {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        distributedTokens.removeAll()
    }

    private func invalidateBuffer() {
        advanceGeneration()
        stateQueue.async { [weak self] in self?.resetStateLocked() }
    }

    private func setLifecycle(running: Bool, paused: Bool) {
        lifecycleLock.withLock { lifecycleRunning = running; lifecyclePaused = paused }
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        generationLock.withLock { eventGeneration &+= 1; return eventGeneration }
    }

    private func currentGeneration() -> UInt64 { generationLock.withLock { eventGeneration } }
    private func generationIsCurrent(_ expected: UInt64) -> Bool { generationLock.withLock { eventGeneration == expected } }

    private func resetBuffer() {
        buffer.reset()
        bufferSourceID = nil
    }

    private func resetStateLocked() {
        resetBuffer()
        testShortcutArmed = false
        testShortcutF12Released = false
        clearPendingService()
    }

    private func publish(_ status: String) {
        Self.statusLogger.notice("\(status, privacy: .public)")
        DispatchQueue.main.async { [statusHandler] in statusHandler(status) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
