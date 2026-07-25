import SwiftUI
import AppKit

struct AppRowView: View {
    @EnvironmentObject private var manager: RunningAppsManager
    @EnvironmentObject private var settings: AppSettings

    let entry: RunningAppsManager.TrackedApp
    let now: Date

    private var idleEnabled: Binding<Bool> {
        Binding(
            get: { manager.isIdleQuitEnabled(entry.app) },
            set: { manager.setIdleQuitEnabled($0, for: entry.app) }
        )
    }

    private var windowEnabled: Binding<Bool> {
        Binding(
            get: { manager.isWindowQuitEnabled(entry.app) },
            set: { manager.setWindowQuitEnabled($0, for: entry.app) }
        )
    }

    private var idleDurationSelection: Binding<Int> {
        Binding(
            get: { manager.idleMinutesOverride(for: entry.app) ?? 0 },
            set: { manager.setIdleMinutesOverride($0 == 0 ? nil : $0, for: entry.app) }
        )
    }

    var body: some View {
        let idleMinutes = manager.idleMinutes(for: entry.app)
        let remaining = QuitPolicy.remainingSeconds(lastActive: entry.lastActive, now: now, idleMinutes: idleMinutes)
        let closingSoon = remaining < min(3600, idleMinutes * 15) && idleEnabled.wrappedValue
        let pending = manager.pendingQuits[entry.id]
        let appName = entry.app.localizedName ?? "Unknown"

        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(nsImage: AppIconCache.icon(for: entry.app))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text(appName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fontWeight(closingSoon || pending != nil ? .semibold : .regular)

                Spacer(minLength: 8)

                if pending != nil {
                    Text("Quitting soon")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if manager.terminationPending.contains(entry.id) {
                    Text("Waiting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if idleEnabled.wrappedValue {
                    Text(IdleDuration.shortRemaining(seconds: remaining))
                        .monospacedDigit()
                        .fontWeight(closingSoon ? .semibold : .regular)
                        .foregroundStyle(closingSoon ? Color.primary : Color.secondary)
                }

                Picker("Idle duration for \(appName)", selection: idleDurationSelection) {
                    Text("Default").tag(0)
                    ForEach(IdleDuration.stepsInMinutes, id: \.self) { minutes in
                        Text(IdleDuration.label(minutes: minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 82)
                .disabled(!idleEnabled.wrappedValue)

                Button {
                    manager.resetTimer(for: entry.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .disabled(!idleEnabled.wrappedValue)
                .accessibilityLabel("Reset idle timer for \(appName)")

                if settings.showQuitButton {
                    Button {
                        manager.quit(entry.app)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.terminationPending.contains(entry.id))
                    .accessibilityLabel("Quit \(appName)")
                }
            }

            HStack(spacing: 14) {
                Toggle("Idle quit", isOn: idleEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!manager.canConfigure(entry.app))
                    .accessibilityLabel("Automatically quit \(appName) when idle")

                Toggle("Last-window quit", isOn: windowEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!manager.canConfigure(entry.app) || !settings.quitOnLastWindowClosed)
                    .accessibilityLabel("Quit \(appName) when its last window closes")

                Spacer()

                if pending != nil {
                    Button("Cancel") { manager.cancelPendingQuit(for: entry.id) }
                        .controlSize(.small)
                    Button("Snooze 15 min") { manager.snoozePendingQuit(for: entry.id) }
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }
}

/// Icon lookups are not cheap; the menu re-renders every second while open.
@MainActor
enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(for app: NSRunningApplication) -> NSImage {
        guard let path = app.bundleURL?.path ?? app.executableURL?.path, !path.isEmpty else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
