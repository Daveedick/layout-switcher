import AppKit
import Foundation

@main
enum ClipboardReplacementCheck {
    static func main() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("local.layout-switcher.check.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        guard seedOriginal(pasteboard) else { fail("could not seed isolated pasteboard") }
        let original = snapshot(pasteboard)

        guard let confirmed = ClipboardReplacement.prepare(text: "converted text", pasteboard: pasteboard) else {
            fail("prepare rejected readable isolated pasteboard")
        }
        guard confirmed.isPreparedReplacementCurrent(),
              pasteboard.string(forType: .string) == "converted text",
              pasteboard.pasteboardItems?.flatMap(\.types).contains(where: { $0.rawValue.hasPrefix("org.codex.layout-switcher.replacement.") }) == true else {
            fail("replacement text or ownership marker missing")
        }
        confirmed.finish(confirmed: true)
        guard snapshot(pasteboard) == original else { fail("confirmed finish did not restore every flavor and item") }

        guard let cancelled = ClipboardReplacement.prepare(text: "will not paste", pasteboard: pasteboard) else {
            fail("second prepare failed")
        }
        guard ClipboardReplacement.prepare(text: "overlap", pasteboard: pasteboard) == nil else {
            fail("overlapping transaction was accepted")
        }
        pasteboard.clearContents()
        pasteboard.setString("external clipboard owner", forType: .string)
        guard !cancelled.isPreparedReplacementCurrent() else {
            fail("transaction still reported ownership after an external clipboard change")
        }
        cancelled.cancelBeforeDispatch()
        guard pasteboard.string(forType: .string) == "external clipboard owner" else {
            fail("cancel overwrote an external clipboard change")
        }

        guard let readiness = ClipboardReplacement.prepare(text: "readiness", pasteboard: pasteboard),
              !ClipboardReplacement.isReadyForInputReplay() else {
            fail("input replay was allowed while replacement clipboard was still owned")
        }
        pasteboard.clearContents()
        pasteboard.setString("external readiness owner", forType: .string)
        guard ClipboardReplacement.isReadyForInputReplay(),
              pasteboard.string(forType: .string) == "external readiness owner" else {
            fail("stale transaction blocked replay or overwrote external clipboard")
        }
        readiness.finish(confirmed: false)

        guard let delayed = ClipboardReplacement.prepare(text: "delayed", pasteboard: pasteboard) else {
            fail("delayed prepare failed")
        }
        delayed.finish(confirmed: false)
        pasteboard.clearContents()
        pasteboard.setString("external delayed owner", forType: .string)
        pumpMainRunLoop(for: 1.2)
        guard pasteboard.string(forType: .string) == "external delayed owner" else {
            fail("delayed restore overwrote an external clipboard change")
        }

        guard seedOriginal(pasteboard),
              let workerFinished = ClipboardReplacement.prepare(text: "worker restore", pasteboard: pasteboard) else {
            fail("worker restore prepare failed")
        }
        let workerGroup = DispatchGroup()
        let resultLock = NSLock()
        var workerFinishResult = false
        workerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = workerFinished.finish(confirmed: false)
            resultLock.lock(); workerFinishResult = result; resultLock.unlock()
            workerGroup.leave()
        }
        let workerDeadline = Date().addingTimeInterval(3)
        var workerReturned = false
        while Date() < workerDeadline {
            if workerGroup.wait(timeout: .now()) == .success { workerReturned = true; break }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        guard workerReturned else { fail("AX-worker finish did not return while main run loop was pumped") }
        resultLock.lock(); let workerRestoreSucceeded = workerFinishResult; resultLock.unlock()
        guard workerRestoreSucceeded, snapshot(pasteboard) == original else {
            fail("AX-worker finish returned before restoring its owned clipboard")
        }

        guard seedOriginal(pasteboard),
              let delayedUnchanged = ClipboardReplacement.prepare(text: "delayed restore", pasteboard: pasteboard) else {
            fail("delayed unchanged prepare failed")
        }
        delayedUnchanged.finish(confirmed: false)
        pumpMainRunLoop(for: 1.0)
        guard snapshot(pasteboard) == original else { fail("delayed finish did not restore unchanged clipboard") }

        let emptyPasteboard = NSPasteboard(name: NSPasteboard.Name("local.layout-switcher.empty-check.\(UUID().uuidString)"))
        defer { emptyPasteboard.releaseGlobally() }
        emptyPasteboard.clearContents()
        guard let emptyTransaction = ClipboardReplacement.prepare(text: "temporary", pasteboard: emptyPasteboard) else {
            fail("empty-pasteboard prepare failed")
        }
        guard emptyTransaction.finish(confirmed: true), emptyPasteboard.pasteboardItems?.isEmpty ?? true else {
            fail("empty clipboard was not restored after confirmed finish")
        }

        guard seedOriginal(pasteboard),
              ClipboardReplacement.prepare(text: "shutdown flush", pasteboard: pasteboard) != nil else {
            fail("shutdown flush prepare failed")
        }
        ClipboardReplacement.flushIfOwned()
        guard snapshot(pasteboard) == original else { fail("shutdown flush did not restore the owned pasteboard") }

        let oversizedPasteboard = NSPasteboard(name: NSPasteboard.Name("local.layout-switcher.large-check.\(UUID().uuidString)"))
        defer { oversizedPasteboard.releaseGlobally() }
        oversizedPasteboard.clearContents()
        oversizedPasteboard.setData(Data(repeating: 0x41, count: 64 * 1024 * 1024 + 1), forType: .string)
        let oversizedBefore = snapshot(oversizedPasteboard)
        guard ClipboardReplacement.prepare(text: "replacement", pasteboard: oversizedPasteboard) == nil,
              snapshot(oversizedPasteboard) == oversizedBefore else {
            fail("oversized clipboard snapshot was not rejected unchanged")
        }

        guard !ClipboardReplacement.transformCopiedText(on: pasteboard, transform: { $0.uppercased() }),
              snapshot(pasteboard) == original else { fail("manual transform changed a multi-item pasteboard") }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let hidden = makeItem("concealed", customType: concealed.rawValue, customData: Data())
        pasteboard.clearContents()
        guard pasteboard.writeObjects([hidden]),
              !ClipboardReplacement.transformCopiedText(on: pasteboard, transform: { $0.uppercased() }),
              pasteboard.string(forType: .string) == "concealed" else {
            fail("manual transform changed concealed content")
        }
        pasteboard.clearContents()
        pasteboard.setString("example", forType: .string)
        guard let busy = ClipboardReplacement.prepare(text: "temporary edit", pasteboard: pasteboard),
              !ClipboardReplacement.transformCopiedText(on: pasteboard, transform: { $0.uppercased() }),
              busy.finish(confirmed: true),
              ClipboardReplacement.transformCopiedText(on: pasteboard, transform: { $0.uppercased() }),
              pasteboard.string(forType: .string) == "EXAMPLE" else {
            fail("manual text transform failed or interfered with an active transaction")
        }
        let staleConversion = ClipboardReplacement.transformCopiedText(on: pasteboard) { _ in
            pasteboard.clearContents()
            pasteboard.setString("new copy", forType: .string)
            return "stale result"
        }
        guard !staleConversion, pasteboard.string(forType: .string) == "new copy" else {
            fail("manual text transform overwrote a newer copy")
        }

        print("PASS: isolated pasteboard restoration, ownership/readiness, overlap, delayed worker finish, empty clipboard, flush, size bound, and manual text transform")
    }

    private static func makeItem(_ text: String, customType: String, customData: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(text.utf8), forType: .string)
        item.setData(customData, forType: NSPasteboard.PasteboardType(customType))
        return item
    }

    private static func seedOriginal(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let items = [makeItem("first", customType: "org.example.first", customData: Data([0, 1, 255])),
                     makeItem("second", customType: "org.example.second", customData: Data([9, 8, 7, 6]))]
        return pasteboard.writeObjects(items)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, Data($0)) }
            })
        }
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
