import Dispatch
import Foundation
import LayoutSwitcherCore

@main
enum InputSourceThreadCheck {
    static func main() {
        let expected = [InputSources.abcID, InputSources.russianWinID]
        let stateLock = NSLock()
        var failure: String?
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            for _ in 0..<20 {
                let available = InputSources.available().map(\.id)
                let availableSet = Set(available)
                guard !available.isEmpty else {
                    stateLock.lock(); failure = "empty input source list"; stateLock.unlock()
                    return
                }
                for id in expected {
                    let listed = availableSet.contains(id)
                    let queried = InputSources.isAvailable(id: id)
                    guard listed, queried == listed else {
                        stateLock.lock(); failure = "expected input source unavailable or inconsistent"; stateLock.unlock()
                        return
                    }
                }
                guard let current = InputSources.currentID(), availableSet.contains(current) else {
                    stateLock.lock(); failure = "current input source is missing from available list"; stateLock.unlock()
                    return
                }
                let key = TypedKey(keyCode: 5, shift: false, caps: false)
                guard InputSources.text(for: key, sourceID: InputSources.abcID) == "g",
                      InputSources.text(for: key, sourceID: InputSources.russianWinID) == "п",
                      let upper = InputSources.key(for: "П", sourceID: InputSources.russianWinID),
                      upper.shift, !upper.caps,
                      InputSources.text(for: upper, sourceID: InputSources.russianWinID) == "П" else {
                    stateLock.lock(); failure = "physical key mapping mismatch"; stateLock.unlock()
                    return
                }
            }
        }

        let deadline = Date().addingTimeInterval(10)
        var completed = false
        while Date() < deadline {
            if group.wait(timeout: .now()) == .success { completed = true; break }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard completed else {
            fputs("FAIL: InputSources background checks timed out\n", stderr)
            exit(1)
        }
        stateLock.lock()
        let result = failure
        stateLock.unlock()
        if let result {
            fputs("FAIL: \(result)\n", stderr)
            exit(1)
        }
        print("PASS: 20 background iterations; \(expected.joined(separator: ", "))")
    }
}
