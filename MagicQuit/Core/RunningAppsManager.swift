import AppKit
import Combine
import os.log

/// Tracks regular apps and quits them once they have been idle for the configured duration.
@MainActor
final class RunningAppsManager: ObservableObject {
    struct TrackedApp: Identifiable {
        let app: NSRunningApplication
        var lastActive: Date
        var id: pid_t { app.processIdentifier }
    }

    struct PendingQuit: Identifiable {
        let pid: pid_t
        let appName: String
        let requestedAt: Date
        let deadline: Date
        var id: pid_t { pid }
    }

    private enum PauseReason: Hashable {
        case sleeping
        case screenLocked
        case sessionInactive
    }

    @Published private(set) var tracked: [pid_t: TrackedApp] = [:]
    @Published private(set) var pendingQuits: [pid_t: PendingQuit] = [:]
    @Published private(set) var terminationPending: Set<pid_t> = []

    let settings: AppSettings
    let windowWatcher: WindowWatcher

    private var sweepTimer: Timer?
    private var dueTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var pauseReasons: Set<PauseReason> = []
    private var pauseStarted: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var quitTasks: [pid_t: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.MagicQuit", category: "RunningAppsManager")

    static let warningDuration: TimeInterval = 30
    static let terminationRetryInterval: TimeInterval = 30

    init(settings: AppSettings) {
        self.settings = settings
        self.windowWatcher = WindowWatcher(settings: settings)
        windowWatcher.terminateHandler = { [weak self] app in self?.requestQuit(app, reason: "last window closed") }

        reconcile()

        let center = NSWorkspace.shared.notificationCenter
        func observeApp(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in handler(app) }
            }
            observerTokens.append(token)
        }

        observeApp(NSWorkspace.didActivateApplicationNotification) { [weak self] app in self?.touch(app) }
        observeApp(NSWorkspace.didDeactivateApplicationNotification) { [weak self] app in self?.touch(app) }
        observeApp(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in self?.track(app) }
        observeApp(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.confirmTermination(app) }

        observerTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.beginPause(.sleeping) }
        })
        observerTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.endPause(.sleeping) }
        })
        observerTokens.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.beginPause(.sessionInactive) }
        })
        observerTokens.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.endPause(.sessionInactive) }
        })

        let distributed = DistributedNotificationCenter.default()
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.beginPause(.screenLocked) }
        })
        distributedTokens.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.endPause(.screenLocked) }
        })

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.sweep() }
        }

        settings.$quitOnLastWindowClosed
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.windowWatcher.refresh(apps: self.tracked.values.map(\.app))
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        sweepTimer?.invalidate()
        dueTimer?.invalidate()
        quitTasks.values.forEach { $0.cancel() }
        let center = NSWorkspace.shared.notificationCenter
        observerTokens.forEach(center.removeObserver)
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.forEach(distributed.removeObserver)
    }

    // MARK: - Tracking

    private func track(_ app: NSRunningApplication) {
        guard QuitPolicy.isTrackable(bundleId: app.bundleIdentifier,
                                     activationPolicy: app.activationPolicy,
                                     ownBundleId: Bundle.main.bundleIdentifier) else { return }
        settings.migrateLegacyToggleIfNeeded(appName: app.localizedName, bundleId: app.bundleIdentifier)
        settings.migrateLegacyIdleDurationIfNeeded(appName: app.localizedName, bundleId: app.bundleIdentifier)
        if tracked[app.processIdentifier] == nil {
            tracked[app.processIdentifier] = TrackedApp(app: app, lastActive: Date())
        }
        windowWatcher.watch(app)
    }

    private func confirmTermination(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        tracked[pid] = nil
        pendingQuits[pid] = nil
        terminationPending.remove(pid)
        quitTasks[pid]?.cancel()
        quitTasks[pid] = nil
        windowWatcher.unwatch(pid)
    }

    private func touch(_ app: NSRunningApplication) {
        track(app)
        tracked[app.processIdentifier]?.lastActive = Date()
        cancelPendingQuit(for: app.processIdentifier)
    }

    private func reconcile() {
        let running = NSWorkspace.shared.runningApplications
        let runningPids = Set(running.map(\.processIdentifier))

        for (pid, entry) in tracked {
            let gone = !runningPids.contains(pid) || entry.app.isTerminated
            let untrackable = !QuitPolicy.isTrackable(bundleId: entry.app.bundleIdentifier,
                                                       activationPolicy: entry.app.activationPolicy,
                                                       ownBundleId: Bundle.main.bundleIdentifier)
            if gone || untrackable {
                confirmTermination(entry.app)
            }
        }

        for app in running { track(app) }
    }

    // MARK: - Pausing

    private func beginPause(_ reason: PauseReason) {
        if pauseReasons.isEmpty { pauseStarted = Date() }
        pauseReasons.insert(reason)
        cancelAllPendingQuits()
    }

    private func endPause(_ reason: PauseReason) {
        pauseReasons.remove(reason)
        guard pauseReasons.isEmpty, let start = pauseStarted else { return }
        pauseStarted = nil
        let paused = Date().timeIntervalSince(start)
        guard paused > 0 else { return }
        let now = Date()
        for pid in tracked.keys {
            if let shifted = tracked[pid]?.lastActive.addingTimeInterval(paused) {
                tracked[pid]?.lastActive = min(shifted, now)
            }
        }
    }

    // MARK: - Quitting

    func sweep() {
        reconcile()
        if let frontmost = NSWorkspace.shared.frontmostApplication { touch(frontmost) }
        windowWatcher.refresh(apps: tracked.values.map(\.app))

        guard pauseReasons.isEmpty else { return }

        let now = Date()
        for entry in tracked.values {
            let idleMinutes = idleMinutes(for: entry.app)
            guard entry.app.isFinishedLaunching,
                  isIdleQuitEnabled(entry.app),
                  !terminationPending.contains(entry.id),
                  QuitPolicy.idleQuitDue(lastActive: entry.lastActive, now: now, idleMinutes: idleMinutes)
            else { continue }
            requestQuit(entry.app, reason: "idle for \(idleMinutes) minutes")
        }
        scheduleDueCheck(now: now)
    }

    private func scheduleDueCheck(now: Date) {
        dueTimer?.invalidate()
        dueTimer = nil
        let soonest = tracked.values
            .filter { isIdleQuitEnabled($0.app) && !terminationPending.contains($0.id) }
            .map {
                QuitPolicy.remainingSeconds(
                    lastActive: $0.lastActive,
                    now: now,
                    idleMinutes: idleMinutes(for: $0.app)
                )
            }
            .min()
        guard let soonest, soonest > 0, soonest < 30 else { return }
        dueTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(soonest) + 1, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.sweep() }
        }
    }

    func requestQuit(_ app: NSRunningApplication, reason: String = "manual") {
        let pid = app.processIdentifier
        guard !app.isTerminated, !terminationPending.contains(pid), pendingQuits[pid] == nil else { return }

        if settings.warnBeforeQuitting && reason != "manual" {
            let deadline = Date().addingTimeInterval(Self.warningDuration)
            pendingQuits[pid] = PendingQuit(
                pid: pid,
                appName: app.localizedName ?? "Unknown app",
                requestedAt: Date(),
                deadline: deadline
            )
            quitTasks[pid] = Task { @MainActor [weak self, weak app] in
                try? await Task.sleep(for: .seconds(Self.warningDuration))
                guard !Task.isCancelled, let self, let app, self.pendingQuits[pid] != nil else { return }
                self.pendingQuits[pid] = nil
                self.performTermination(app, reason: reason)
            }
        } else {
            performTermination(app, reason: reason)
        }
    }

    private func performTermination(_ app: NSRunningApplication, reason: String) {
        let pid = app.processIdentifier
        pendingQuits[pid] = nil
        quitTasks[pid]?.cancel()
        quitTasks[pid] = nil
        guard !app.isTerminated else {
            confirmTermination(app)
            return
        }

        log.info("Requesting quit for \(app.localizedName ?? "unknown", privacy: .private); reason: \(reason, privacy: .private)")
        guard app.terminate() else { return }
        terminationPending.insert(pid)

        quitTasks[pid] = Task { @MainActor [weak self, weak app] in
            try? await Task.sleep(for: .seconds(Self.terminationRetryInterval))
            guard !Task.isCancelled, let self, let app else { return }
            if app.isTerminated {
                self.confirmTermination(app)
            } else {
                // The app may have displayed a save prompt or refused termination.
                // Keep tracking it and allow a later/manual request.
                self.terminationPending.remove(pid)
                self.tracked[pid]?.lastActive = Date()
                self.quitTasks[pid] = nil
            }
        }
    }

    func cancelPendingQuit(for pid: pid_t) {
        pendingQuits[pid] = nil
        quitTasks[pid]?.cancel()
        quitTasks[pid] = nil
        tracked[pid]?.lastActive = Date()
    }

    func snoozePendingQuit(for pid: pid_t, minutes: Int = 15) {
        cancelPendingQuit(for: pid)
        tracked[pid]?.lastActive = Date().addingTimeInterval(TimeInterval(minutes * 60 - idleMinutesForPID(pid) * 60))
    }

    private func cancelAllPendingQuits() {
        for pid in pendingQuits.keys { cancelPendingQuit(for: pid) }
    }

    private func idleMinutesForPID(_ pid: pid_t) -> Int {
        guard let app = tracked[pid]?.app else { return settings.idleMinutes }
        return idleMinutes(for: app)
    }

    func quit(_ app: NSRunningApplication) {
        requestQuit(app, reason: "manual")
    }

    func resetTimer(for pid: pid_t) {
        cancelPendingQuit(for: pid)
        tracked[pid]?.lastActive = Date()
    }

    // MARK: - Per-app policies

    private func exclusionKey(for app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.executableURL?.path
    }

    func canConfigure(_ app: NSRunningApplication) -> Bool {
        exclusionKey(for: app) != nil
    }

    func isIdleQuitEnabled(_ app: NSRunningApplication) -> Bool {
        guard let key = exclusionKey(for: app) else { return false }
        return !settings.idleQuitExcluded.contains(key)
    }

    func isWindowQuitEnabled(_ app: NSRunningApplication) -> Bool {
        guard let key = exclusionKey(for: app) else { return false }
        return !settings.windowQuitExcluded.contains(key)
    }

    func setIdleQuitEnabled(_ enabled: Bool, for app: NSRunningApplication) {
        guard let key = exclusionKey(for: app) else { return }
        if enabled {
            settings.idleQuitExcluded.remove(key)
            resetTimer(for: app.processIdentifier)
        } else {
            settings.idleQuitExcluded.insert(key)
            cancelPendingQuit(for: app.processIdentifier)
        }
    }

    func setWindowQuitEnabled(_ enabled: Bool, for app: NSRunningApplication) {
        guard let key = exclusionKey(for: app) else { return }
        if enabled {
            settings.windowQuitExcluded.remove(key)
        } else {
            settings.windowQuitExcluded.insert(key)
        }
        windowWatcher.refresh(apps: tracked.values.map(\.app))
    }

    func idleMinutes(for app: NSRunningApplication) -> Int {
        settings.idleMinutes(forAppKey: exclusionKey(for: app))
    }

    func idleMinutesOverride(for app: NSRunningApplication) -> Int? {
        settings.idleMinutesOverride(forAppKey: exclusionKey(for: app))
    }

    func setIdleMinutesOverride(_ minutes: Int?, for app: NSRunningApplication) {
        settings.setIdleMinutesOverride(minutes, forAppKey: exclusionKey(for: app))
        resetTimer(for: app.processIdentifier)
    }
}
