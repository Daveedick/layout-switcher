import AppKit
import Foundation
import os

/// LaunchAgent mode. Owns no windows or input permissions and never takes the GUI's lock.
@MainActor
final class Watchdog {
    private static let logger = Logger(subsystem: "local.layout-switcher.app", category: "Watchdog")
    private static let recoveryDelays: [TimeInterval] = [1, 2, 4, 8, 16]
    private static let stableRunDuration: TimeInterval = 60

    private let workspace = NSWorkspace.shared
    private let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    private var application: NSRunningApplication?
    private var observedAt: TimeInterval = 0
    private var shouldLaunch = true
    private var retryTimer: Timer?
    private var launchInProgress = false
    private var observationGeneration = 0
    private var recoveryAttempts = 0
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var terminationObservation: NSKeyValueObservation?

    static func run() -> Never {
        let watchdog = Watchdog()
        watchdog.start()
        withExtendedLifetime(watchdog) {
            RunLoop.main.run()
        }
        exit(0)
    }

    /// Call only after this GUI instance acquires the existing exclusive application lock.
    static func prepareGUI() {
        try? FileManager.default.removeItem(at: cleanExitMarker(for: ProcessInfo.processInfo.processIdentifier))
    }

    /// Call from normal AppKit termination, after finishing the application's cleanup.
    static func markCleanExit() {
        do {
            try Data().write(to: cleanExitMarker(for: ProcessInfo.processInfo.processIdentifier), options: .atomic)
        } catch {
            logger.error("Could not record an orderly GUI exit: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cleanExitMarker(for pid: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("local.layout-switcher.gui-\(pid).clean-exit")
    }

    private func start() {
        // This list includes LSUIElement apps such as Layout Switcher.
        runningApplicationsObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
        reconcile()
    }

    private func matchesBundle(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == bundleURL
    }

    private func observe(_ app: NSRunningApplication) {
        application = app
        observationGeneration &+= 1
        observedAt = ProcessInfo.processInfo.systemUptime
        shouldLaunch = false
        retryTimer?.invalidate()
        retryTimer = nil
        terminationObservation = app.observe(\.isTerminated) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
        if app.isTerminated { processTermination(of: app) }
    }

    private func reconcile() {
        if let application {
            if !application.isTerminated { return }
            processTermination(of: application)
        }
        if let existing = workspace.runningApplications.first(where: { !$0.isTerminated && matchesBundle($0) }) {
            observe(existing)
            return
        }
        if !launchInProgress, shouldLaunch { launchGUI() }
    }

    private func processTermination(of app: NSRunningApplication) {
        application = nil
        terminationObservation = nil
        let marker = Self.cleanExitMarker(for: app.processIdentifier)
        if let values = try? marker.resourceValues(forKeys: [.contentModificationDateKey]),
           let markedAt = values.contentModificationDate,
           app.launchDate.map({ markedAt >= $0 }) ?? true {
            try? FileManager.default.removeItem(at: marker)
            recoveryAttempts = 0
            shouldLaunch = false
            Self.logger.notice("GUI quit normally. Waiting for a manual launch.")
            return
        }
        if ProcessInfo.processInfo.systemUptime - observedAt >= Self.stableRunDuration {
            recoveryAttempts = 0
        }
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard recoveryAttempts < Self.recoveryDelays.count else {
            Self.logger.error("GUI recovery stopped after repeated failures. Waiting for a manual launch.")
            recoveryAttempts = 0
            shouldLaunch = false
            return
        }
        let timer = Timer(timeInterval: Self.recoveryDelays[recoveryAttempts], repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                self.shouldLaunch = true
                self.reconcile()
            }
        }
        timer.tolerance = 0.2
        retryTimer = timer
        recoveryAttempts += 1
        RunLoop.main.add(timer, forMode: .common)
    }

    private func launchGUI() {
        launchInProgress = true
        shouldLaunch = false
        let generation = observationGeneration
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(at: bundleURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchInProgress = false
                // Workspace observation may have found this or a manual instance first.
                guard self.observationGeneration == generation else { return }
                if let app, self.matchesBundle(app) {
                    self.observe(app)
                } else {
                    Self.logger.error("GUI launch failed: \(error?.localizedDescription ?? "unexpected application", privacy: .public)")
                    self.scheduleRecovery()
                }
            }
        }
    }
}
