import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

/// A system-wide focus snapshot. `element` may be absent when an app exposes no focused AX element.
struct FocusContext {
    let pid: pid_t
    let app: AXUIElement
    let element: AXUIElement?
    let window: AXUIElement?
}

enum SelectionProbe {
    case selected(String, FocusContext)
    case none(FocusContext)
    case unavailable(reason: String, context: FocusContext)
    case noFocus(reason: String)
    case protected(reason: String, context: FocusContext?)
}

/// Read-only Accessibility access used by the runtime and the Services fallback.
/// Call off the main thread: every AX request has a short, bounded messaging timeout.
enum SelectionAccess {
    static let serviceTitle = "Layout Switcher: Convert Layout"
    private static let maximumSelectionLength = 2_000
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, "AXComboBox", "AXSearchField",
    ]
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm",
    ]
    private static let messagingTimeout: Float = 0.15
    private struct ProcessIdentity: Hashable {
        let pid: pid_t
        let launchDate: TimeInterval
    }
    private static let electronAXLock = NSLock()
    private static var electronAXCompletedIdentities = Set<ProcessIdentity>()
    private static var electronAXAttempts: [ProcessIdentity: Int] = [:]
    private static var electronAXIdentityOrder: [ProcessIdentity] = []
    private static let diagnosticLock = NSLock()
    private static var probeDiagnostic = "not-probed"

    /// Safe, bounded summary of the most recent probe. It never contains attribute text or titles.
    static func diagnosticSnapshot() -> String { diagnosticLock.withLock { probeDiagnostic } }

    private static func recordDiagnostic(_ value: String) {
        diagnosticLock.withLock { probeDiagnostic = value }
    }

    static func context() -> FocusContext? {
        guard !IsSecureEventInputEnabled() else { return nil }
        return contextForProbe().context
    }

    static func probe() -> SelectionProbe {
        guard !IsSecureEventInputEnabled() else {
            recordDiagnostic("secureInput=enabled")
            return .protected(reason: "secure-event-input", context: nil)
        }
        let initial: (context: FocusContext?, reason: String, diagnostic: String) = contextForProbe()
        guard let initialFocus = initial.context else {
            recordDiagnostic(initial.diagnostic)
            return .noFocus(reason: initial.reason)
        }
        // Prepare known Electron processes even when their initial AX focus element is absent.
        prepareElectronAccessibility(for: initialFocus.pid)
        let refreshed = contextForProbe()
        guard let focus = refreshed.context else {
            recordDiagnostic("initialPid=\(initialFocus.pid);refocus=\(refreshed.diagnostic)")
            return .noFocus(reason: refreshed.reason)
        }
        guard focus.pid == initialFocus.pid else {
            let diagnostic = "initialPid=\(initialFocus.pid);refocusedPid=\(focus.pid)"
            recordDiagnostic(diagnostic)
            return .unavailable(reason: "focused-process-changed", context: initialFocus)
        }
        let isTerminal = NSRunningApplication(processIdentifier: focus.pid)?.bundleIdentifier
            .map(terminalBundleIDs.contains) ?? false
        guard let element = focus.element else {
            let diagnostic = "pid=\(focus.pid);focusedElement=unavailable"
            recordDiagnostic(diagnostic)
            return .unavailable(reason: "focused-element-unavailable", context: focus)
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let roleResult = copyAttribute(element, kAXRoleAttribute)
        guard roleResult.error == .success, let role = roleResult.value as? String else {
            let diagnostic = "pid=\(focus.pid);bundle=\(bundleID(for: focus.pid));role=\(attributeStatus(roleResult))"
            recordDiagnostic(diagnostic)
            return .unavailable(reason: "focused-role-\(axErrorName(roleResult.error))", context: focus)
        }
        switch protection(of: element, role: role) {
        case .protected(let reason):
            recordDiagnostic("pid=\(focus.pid);bundle=\(bundleID(for: focus.pid));role=\(safeIdentifier(role));protection=\(reason)")
            return .protected(reason: reason, context: focus)
        case .unavailable(let reason):
            recordDiagnostic("pid=\(focus.pid);bundle=\(bundleID(for: focus.pid));role=\(safeIdentifier(role));protection=\(reason)")
            return .unavailable(reason: reason, context: focus)
        case .ordinary: break
        }
        guard editableRoles.contains(role) else {
            recordDiagnostic("pid=\(focus.pid);bundle=\(bundleID(for: focus.pid));role=\(safeIdentifier(role));editableRole=no")
            return .unavailable(reason: "unsupported-role", context: focus)
        }

        let selection = copyAttribute(element, kAXSelectedTextAttribute)
        let rangeResult = selectedRangeResult(element)
        let range = rangeResult.range
        let baseDiagnostic = "pid=\(focus.pid);bundle=\(bundleID(for: focus.pid));role=\(safeIdentifier(role));selectedText=\(attributeStatus(selection));selectedTextLength=\(stringLength(selection.value));selectedRange=\(rangeResult.status)"
        let selected: String?
        if selection.error == .success {
            guard let value = selection.value as? String else {
                recordDiagnostic(baseDiagnostic + ";result=selectedText-wrong-type")
                return .unavailable(reason: "selected-text-wrong-type", context: focus)
            }
            selected = value
        } else if selection.error == .noValue || selection.error == .attributeUnsupported {
            selected = nil
        } else {
            recordDiagnostic(baseDiagnostic + ";result=selected-text-read-failed")
            return .unavailable(reason: "selected-text-\(axErrorName(selection.error))", context: focus)
        }
        guard matches(focus) else {
            recordDiagnostic(baseDiagnostic + ";result=focus-changed")
            return .unavailable(reason: "focus-changed-during-probe", context: focus)
        }
        if isTerminal {
            // Terminal output may look editable to AX, but retyping over a screen selection is unsafe.
            if !(selected ?? "").isEmpty || (range?.length ?? 0) > 0 {
                recordDiagnostic(baseDiagnostic + ";protection=terminal-selection")
                return .protected(reason: "terminal-selection", context: focus)
            }
            guard range != nil else {
                recordDiagnostic(baseDiagnostic + ";result=terminal-range-unavailable")
                return .unavailable(reason: "terminal-range-unavailable", context: focus)
            }
            recordDiagnostic(baseDiagnostic + ";result=none")
            return .none(focus)
        }
        if let selected, !selected.isEmpty {
            // AXSelectedText is authoritative. Some editable controls expose ranges that are
            // absent or not aligned with the returned selected string.
            guard selected.utf16.count <= maximumSelectionLength,
                  range.map({ $0.length > 0 }) ?? true else {
                let reason = selected.utf16.count > maximumSelectionLength ? "selection-too-long" : "selected-text-with-zero-range"
                recordDiagnostic(baseDiagnostic + ";result=\(reason)")
                return .unavailable(reason: reason, context: focus)
            }
            recordDiagnostic(baseDiagnostic + ";result=selected")
            return .selected(selected, focus)
        }
        // An empty text value or optional noValue/unsupported response plus a readable zero range
        // is sufficient to establish that an ordinary editable control has no selection.
        if range?.length == 0 {
            recordDiagnostic(baseDiagnostic + ";result=none")
            return .none(focus)
        }
        recordDiagnostic(baseDiagnostic + ";result=selection-state-unknown")
        return .unavailable(reason: "selection-state-unknown", context: focus)
    }

    private static func contextForProbe() -> (context: FocusContext?, reason: String, diagnostic: String) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        let focusedElementResult = copyAttribute(system, kAXFocusedUIElementAttribute)
        let focusedApplicationResult = copyAttribute(system, kAXFocusedApplicationAttribute)
        let focusedElement = focusedElementResult.error == .success ? focusedElementResult.value.flatMap(asElement) : nil
        let focusedApplication = focusedApplicationResult.error == .success ? focusedApplicationResult.value.flatMap(asElement) : nil
        if let focusedElement { AXUIElementSetMessagingTimeout(focusedElement, messagingTimeout) }

        var pid: pid_t = 0
        var pidError: AXError = .failure
        if let focusedElement {
            pidError = AXUIElementGetPid(focusedElement, &pid)
            guard pidError == .success, pid > 0 else {
                let diagnostic = "focusedElement=\(attributeStatus(focusedElementResult));focusedApplication=\(attributeStatus(focusedApplicationResult));focusedElementPid=\(axErrorName(pidError))"
                return (nil, "focused-element-pid-\(axErrorName(pidError))", diagnostic)
            }
        } else if let focusedApplication {
            pidError = AXUIElementGetPid(focusedApplication, &pid)
            guard pidError == .success, pid > 0 else {
                let diagnostic = "focusedElement=\(attributeStatus(focusedElementResult));focusedApplication=\(attributeStatus(focusedApplicationResult));focusedApplicationPid=\(axErrorName(pidError))"
                return (nil, "focused-application-pid-\(axErrorName(pidError))", diagnostic)
            }
        } else {
            let diagnostic = "focusedElement=\(attributeStatus(focusedElementResult));focusedApplication=\(attributeStatus(focusedApplicationResult));pid=unavailable"
            return (nil, "no-focused-element-or-application", diagnostic)
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let window = focusedElement.flatMap { copyElement($0, kAXWindowAttribute) }
            ?? copyElement(app, kAXFocusedWindowAttribute)
        if let window { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
        let diagnostic = "pid=\(pid);bundle=\(bundleID(for: pid));focusedElement=\(attributeStatus(focusedElementResult));focusedApplication=\(attributeStatus(focusedApplicationResult))"
        return (FocusContext(pid: pid, app: app, element: focusedElement, window: window), "", diagnostic)
    }

    /// Checks that the same process and, when exposed, the same focused element/window still own focus.
    static func matches(_ context: FocusContext) -> Bool {
        guard !IsSecureEventInputEnabled(), let current = contextSnapshot() else { return false }
        guard current.pid == context.pid else { return false }
        if let expectedElement = context.element {
            guard let currentElement = current.element, CFEqual(expectedElement, currentElement) else { return false }
        } else if let expectedWindow = context.window {
            guard let currentWindow = current.window, CFEqual(expectedWindow, currentWindow) else { return false }
        }
        return true
    }

    /// Presses only this app's Services item in the focused application's app menu.
    /// Invoke off the main thread; AX menu traversal can block on app IPC.
    static func pressService(in context: FocusContext) -> Bool {
        guard matches(context), let appMenu = copyElement(context.app, kAXMenuBarAttribute),
              let topItems = children(appMenu), !topItems.isEmpty else { return false }
        // Some AX implementations omit the Apple item. Scan the first two menu roots
        // for the exact service title instead of assuming a fixed app-menu index.
        let deadline = DispatchTime.now().uptimeNanoseconds + 350_000_000
        var remainingNodes = 128
        var found: AXUIElement?
        for root in topItems.prefix(2) {
            if let service = findService(in: root, depth: 0, deadline: deadline, remainingNodes: &remainingNodes) {
                found = service
                break
            }
        }
        guard let service = found, matches(context),
              attribute(service, kAXEnabledAttribute) as? Bool == true else { return false }
        return AXUIElementPerformAction(service, kAXPressAction as CFString) == .success
    }

    private static func contextSnapshot() -> FocusContext? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        let element = copyElement(system, kAXFocusedUIElementAttribute)
        if let element { AXUIElementSetMessagingTimeout(element, messagingTimeout) }
        let focusedApp = copyElement(system, kAXFocusedApplicationAttribute)
        var pid: pid_t = 0
        if let element {
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        } else if let focusedApp {
            guard AXUIElementGetPid(focusedApp, &pid) == .success, pid > 0 else { return nil }
        } else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let window = element.flatMap { copyElement($0, kAXWindowAttribute) }
            ?? copyElement(app, kAXFocusedWindowAttribute)
        return FocusContext(pid: pid, app: app, element: element, window: window)
    }

    /// Electron apps may publish their AX tree only after an assistive client enables manual accessibility.
    /// This is called from the AX worker during selection probes, never for each key captured by the tap.
    private static func prepareElectronAccessibility(for pid: pid_t) {
        guard !IsSecureEventInputEnabled(),
              let process = NSRunningApplication(processIdentifier: pid),
              let bundleURL = process.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let frameworksURL = bundle.privateFrameworksURL,
              FileManager.default.fileExists(atPath: frameworksURL
                .appendingPathComponent("Electron Framework.framework").path) else { return }

        let identity = ProcessIdentity(pid: pid, launchDate: process.launchDate?.timeIntervalSince1970 ?? 0)
        electronAXLock.lock()
        let completed = electronAXCompletedIdentities.contains(identity)
        let attempts = electronAXAttempts[identity, default: 0]
        if !completed, attempts < 3 {
            electronAXAttempts[identity] = attempts + 1
            if !electronAXIdentityOrder.contains(identity) {
                electronAXIdentityOrder.append(identity)
                if electronAXIdentityOrder.count > 32 {
                    let expired = electronAXIdentityOrder.removeFirst()
                    electronAXAttempts.removeValue(forKey: expired)
                    electronAXCompletedIdentities.remove(expired)
                }
            }
        }
        electronAXLock.unlock()
        guard !completed, attempts < 3, !IsSecureEventInputEnabled() else { return }
        if attempts > 0 {
            let backoffMicroseconds: useconds_t = [100_000, 250_000][min(attempts - 1, 1)]
            usleep(backoffMicroseconds)
            guard !IsSecureEventInputEnabled() else { return }
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let attribute = "AXManualAccessibility" as CFString
        let current = copyAttribute(app, attribute)
        if current.error == .success, let enabled = current.value as? Bool, enabled {
            _ = electronAXLock.withLock { electronAXCompletedIdentities.insert(identity) }
            return
        }
        let mayEnable = (current.error == .success && current.value as? Bool == false)
            || current.error == .attributeUnsupported || current.error == .noValue
        guard mayEnable, !IsSecureEventInputEnabled() else { return }

        let result = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        guard result == .success, !IsSecureEventInputEnabled() else { return }
        _ = electronAXLock.withLock { electronAXCompletedIdentities.insert(identity) }
        // Give Electron/WebKit a short worker-side interval to publish its tree after enabling AX.
        usleep(150_000)
    }

    private enum ProtectionProbe { case protected(String), ordinary, unavailable(String) }

    private static func protection(of element: AXUIElement, role: String) -> ProtectionProbe {
        if role == "AXSecureTextField" { return .protected("secure-role") }
        let subrole = copyAttribute(element, kAXSubroleAttribute)
        if subrole.error == .success, let value = subrole.value as? String {
            if value == (kAXSecureTextFieldSubrole as String) { return .protected("secure-subrole") }
        } else if subrole.error == .success {
            return .unavailable("subrole-wrong-type")
        } else if subrole.error != .attributeUnsupported && subrole.error != .noValue {
            return .unavailable("subrole-\(axErrorName(subrole.error))")
        }
        let protectedContent = copyAttribute(element, "AXIsProtectedContent")
        if protectedContent.error == .success, let isProtected = protectedContent.value as? Bool {
            if isProtected { return .protected("protected-content-attribute") }
        } else if protectedContent.error == .success {
            return .unavailable("protected-content-wrong-type")
        } else if protectedContent.error != .attributeUnsupported && protectedContent.error != .noValue {
            return .unavailable("protected-content-\(axErrorName(protectedContent.error))")
        }
        // Missing optional subroles are normal on ordinary editable controls. A secure role itself
        // is handled above; IPC failures remain unavailable, never an empty selection.
        return .ordinary
    }

    private static func selectedRangeResult(_ element: AXUIElement) -> (range: CFRange?, status: String) {
        let result = copyAttribute(element, kAXSelectedTextRangeAttribute)
        guard result.error == .success else { return (nil, axErrorName(result.error)) }
        guard let value = result.value else { return (nil, "success-nil") }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return (nil, "wrong-type") }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return (nil, "invalid-range") }
        return (range, "success(location:\(range.location),length:\(range.length))")
    }

    private static func attributeStatus(_ result: (value: CFTypeRef?, error: AXError)) -> String {
        guard result.error == .success else { return axErrorName(result.error) }
        guard let value = result.value else { return "success-nil" }
        if CFGetTypeID(value) == CFStringGetTypeID() { return "success-string" }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return "success-bool" }
        if CFGetTypeID(value) == AXValueGetTypeID() { return "success-axvalue" }
        return "success-other"
    }

    private static func stringLength(_ value: CFTypeRef?) -> Int {
        (value as? String)?.utf16.count ?? -1
    }

    private static func axErrorName(_ error: AXError) -> String {
        "ax-\(error.rawValue)"
    }

    private static func bundleID(for pid: pid_t) -> String {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return "unknown" }
        return safeIdentifier(bundleID)
    }

    private static func safeIdentifier(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func asElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: CFString) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return (value, error)
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        copyAttribute(element, name as CFString)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        attribute(element, name as CFString)
    }

    private static func copyString(_ element: AXUIElement, _ name: String) -> String? {
        copyString(element, name as CFString)
    }

    private static func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        copyElement(element, name as CFString)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        let result = copyAttribute(element, name)
        return result.error == .success ? result.value : nil
    }

    private static func copyString(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func copyElement(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        guard let value = attribute(element, kAXChildrenAttribute as CFString) else { return nil }
        return (value as? [AXUIElement])
    }

    /// Service discovery follows the menu-based approach in MIT-licensed ShiftSwitch
    /// (Ilya Makarov, commit 69099f0601ee66ca620a75fe216c6a8d2fe49452), with bounded traversal and focus checks.
    private static func findService(in element: AXUIElement, depth: Int,
                                    deadline: UInt64, remainingNodes: inout Int) -> AXUIElement? {
        guard depth <= 5, remainingNodes > 0,
              DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
        remainingNodes -= 1
        if copyString(element, kAXTitleAttribute as CFString) == serviceTitle,
           copyString(element, kAXRoleAttribute as CFString) == (kAXMenuItemRole as String) {
            return element
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
        guard let descendants = children(element) else { return nil }
        for child in descendants {
            guard DispatchTime.now().uptimeNanoseconds < deadline, remainingNodes > 0 else { return nil }
            if let found = findService(in: child, depth: depth + 1,
                                       deadline: deadline, remainingNodes: &remainingNodes) { return found }
        }
        return nil
    }
}
