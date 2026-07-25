import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject private var manager: RunningAppsManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    @State private var searchText = ""
    @State private var sortByRemaining = false

    private var visibleApps: [RunningAppsManager.TrackedApp] {
        let filtered = manager.tracked.values.filter { entry in
            searchText.isEmpty || (entry.app.localizedName ?? "").localizedCaseInsensitiveContains(searchText)
        }
        if sortByRemaining {
            return filtered.sorted {
                let lhs = QuitPolicy.remainingSeconds(lastActive: $0.lastActive, now: Date(), idleMinutes: manager.idleMinutes(for: $0.app))
                let rhs = QuitPolicy.remainingSeconds(lastActive: $1.lastActive, now: Date(), idleMinutes: manager.idleMinutes(for: $1.app))
                return lhs < rhs
            }
        }
        return filtered.sorted {
            ($0.app.localizedName ?? "").localizedCaseInsensitiveCompare($1.app.localizedName ?? "") == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Soonest first", isOn: $sortByRemaining)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let rows = VStack(spacing: 2) {
                    ForEach(visibleApps) { entry in
                        AppRowView(entry: entry, now: context.date)
                        if entry.id != visibleApps.last?.id { Divider() }
                    }
                }
                if visibleApps.count > 10 {
                    ScrollView { rows }
                        .frame(height: 460)
                } else {
                    rows
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if !manager.pendingQuits.isEmpty {
                Text("\(manager.pendingQuits.count) automatic quit request(s) can be canceled above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if settings.quitOnLastWindowClosed && !WindowWatcher.isTrusted {
                MenuActionButton(title: "Grant Accessibility Access…") {
                    WindowWatcher.promptForAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            MenuActionButton(title: "Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuActionButton(title: "Quit MagicQuit") {
                NSApp.terminate(nil)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 460)
    }
}

struct MenuActionButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isHovered ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovered = $0 }
    }
}
