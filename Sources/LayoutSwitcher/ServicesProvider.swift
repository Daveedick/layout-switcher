import AppKit

/// Entry point for the macOS Services menu. The runtime callback must stay fast and avoid AX IPC;
/// focus validation belongs to its worker before it arms a pending Services conversion.
final class LayoutSwitcherServiceProvider: NSObject {
    private let convertSelection: (String) -> String?

    init(convertSelection: @escaping (String) -> String?) {
        self.convertSelection = convertSelection
    }

    @objc func convertLayout(_ pasteboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard pasteboard.name != NSPasteboard.Name.general,
              let source = pasteboard.string(forType: .string),
              let converted = convertSelection(source) else { return }
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)
    }
}
