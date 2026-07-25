import AppKit
import ApplicationServices
import os.log

/// Quits an app once its last window closes, using the Accessibility API.
@MainActor
final class WindowWatcher {
    var terminateHandler: ((NSRunningApplication) -> Void)?

    private struct Watch {
        let observer: AXObserver
        let element: AXUIElement
        var hadWindows: Bool
        let generation: Int
    }

    private let settings: AppSettings
    private var watches: [pid_t: Watch] = [:]
    private var nextGeneration = 0
    private var loggedActive: Bool?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.MagicQuit", category: "WindowWatcher")

    static let quitDelay: TimeInterval = 2

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private var active: Bool { settings.quitOnLastWindowClosed && Self.isTrusted }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refresh(apps: [NSRunningApplication]) {
        let isActive = active
        if loggedActive != isActive {
            loggedActive = isActive
            log.info("window-close watcher \(isActive ? "active" : "inactive", privacy: .public)")
        }
        guard isActive else {
            for pid in Array(watches.keys) { unwatch(pid) }
            return
        }
        for app in apps { watch(app) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (pid, watch) in watches {
            let windows = Self.windowList(of: watch.element)
            if watch.hadWindows {
                if windows.isEmpty { scheduleWindowCountCheck(pid: pid, generation: watch.generation) }
            } else if !windows.isEmpty {
                for window in windows {
                    AXObserverAddNotification(watch.observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
                }
                watches[pid]?.hadWindows = true
            }
        }
    }

    func watch(_ app: NSRunningApplication) {
        guard active else { return }
        let pid = app.processIdentifier
        guard watches[pid] == nil, pid > 0, app.isFinishedLaunching else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, windowWatcherCallback, &observer) == .success, let observer else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        let windows = Self.windowList(of: element)
        for window in windows {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        nextGeneration += 1
        watches[pid] = Watch(observer: observer, element: element, hadWindows: !windows.isEmpty, generation: nextGeneration)
    }

    func unwatch(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(watch.observer, watch.element, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .defaultMode)
    }

    fileprivate func handle(notification: String, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard watches[pid] != nil else { return }

        if notification == (kAXWindowCreatedNotification as String) {
            watches[pid]?.hadWindows = true
            if let watch = watches[pid] {
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                AXObserverAddNotification(watch.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
            }
        } else if notification == (kAXUIElementDestroyedNotification as String),
                  let generation = watches[pid]?.generation {
            scheduleWindowCountCheck(pid: pid, generation: generation)
        }
    }

    private func scheduleWindowCountCheck(pid: pid_t, generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.quitDelay))
            self?.checkWindowCount(pid: pid, generation: generation)
        }
    }

    private func checkWindowCount(pid: pid_t, generation: Int) {
        guard active, let watch = watches[pid], watch.generation == generation, watch.hadWindows else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            unwatch(pid)
            return
        }
        let name = app.localizedName ?? "unknown"
        if let key = app.bundleIdentifier ?? app.executableURL?.path,
           settings.windowQuitExcluded.contains(key) {
            log.debug("window check excluded: \(name, privacy: .private)")
            return
        }
        guard app.isFinishedLaunching else { return }
        if let launched = app.launchDate, Date().timeIntervalSince(launched) < 30 { return }

        let axCount = Self.windowList(of: watch.element).count
        guard axCount == 0 else { return }

        let cgCount = Self.cgWindowCount(pid: pid)
        guard cgCount == 0 else { return }

        log.info("Last window closed for \(name, privacy: .private)")
        terminateHandler?(app)
    }

    private static func windowList(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return value as! [AXUIElement]
    }

    private static func cgWindowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.count { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  ((info[kCGWindowLayer as String] as? Int) ?? 0) == 0 else { return false }
            if (info[kCGWindowIsOnscreen as String] as? Bool) == true { return true }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 0
            let bounds = (info[kCGWindowBounds as String] as? [String: Double]) ?? [:]
            return alpha > 0 && (bounds["Width"] ?? 0) >= 64 && (bounds["Height"] ?? 0) >= 64
        }
    }
}

private func windowWatcherCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.handle(notification: notification as String, element: element)
    }
}
