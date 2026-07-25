import AppKit
import Combine

struct MagicQuitConfiguration: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let idleMinutes: Int
    let showQuitButton: Bool
    let quitOnLastWindowClosed: Bool
    let warnBeforeQuitting: Bool
    let idleQuitExcluded: [String]
    let windowQuitExcluded: [String]
    let perAppIdleMinutes: [String: Int]
}

enum ConfigurationError: LocalizedError {
    case unsupportedVersion(Int)
    case unsupportedDuration(Int)
    case invalidAppIdentifier(String)
    case duplicateAppIdentifier(String)
    case tooManyEntries(Int)
    case fileTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported MagicQuit configuration version: \(version)."
        case .unsupportedDuration(let minutes):
            "Unsupported idle duration: \(minutes) minutes."
        case .invalidAppIdentifier(let identifier):
            "Invalid app identifier: \(identifier)."
        case .duplicateAppIdentifier(let identifier):
            "Duplicate app identifier: \(identifier)."
        case .tooManyEntries(let count):
            "Configuration contains too many app entries (\(count))."
        case .fileTooLarge(let bytes):
            "Configuration file is too large (\(bytes) bytes)."
        }
    }
}

/// Single source of truth for user settings.
///
/// Settings are mirrored to a stable Application Support JSON file so a new
/// signed build, a rebuilt fork, or a restored app can reuse them without the
/// user importing or re-entering configuration. Existing UserDefaults values
/// are retained as a migration source and compatibility fallback.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let idleMinutes = "idleMinutes"
        static let showQuitButton = "showCloseButton"
        static let quitOnLastWindowClosed = "quitOnLastWindowClosed"
        static let warnBeforeQuitting = "warnBeforeQuitting"
        static let idleQuitExcluded = "idleQuitExcludedApps"
        static let windowQuitExcluded = "windowQuitExcludedApps"
        static let perAppIdleMinutes = "perAppIdleMinutes"
        static let legacyHours = "hoursUntilClose"
        static let legacyToggles = "com.MagicQuit.toggleStatus"
        static let legacyAppIdleHours = "com.MagicQuit.appIdleHours"
    }

    static let maximumConfigurationBytes = 1_048_576
    static let maximumAppEntries = 2_000

    static let defaultWindowQuitExcluded: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.podcasts",
        "org.videolan.vlc",
        "us.zoom.xos",
        "com.microsoft.teams2",
    ]

    private let defaults: UserDefaults
    private let configurationURL: URL
    private var isInitializing = true

    @Published var idleMinutes: Int {
        didSet {
            idleMinutes = IdleDuration.stepAtLeast(minutes: idleMinutes)
            defaults.set(idleMinutes, forKey: Keys.idleMinutes)
            persistConfigurationIfReady()
        }
    }

    @Published var showQuitButton: Bool {
        didSet {
            defaults.set(showQuitButton, forKey: Keys.showQuitButton)
            persistConfigurationIfReady()
        }
    }

    @Published var quitOnLastWindowClosed: Bool {
        didSet {
            defaults.set(quitOnLastWindowClosed, forKey: Keys.quitOnLastWindowClosed)
            persistConfigurationIfReady()
        }
    }

    @Published var warnBeforeQuitting: Bool {
        didSet {
            defaults.set(warnBeforeQuitting, forKey: Keys.warnBeforeQuitting)
            persistConfigurationIfReady()
        }
    }

    /// App identifiers excluded from idle quitting.
    @Published var idleQuitExcluded: Set<String> {
        didSet {
            defaults.set(Array(idleQuitExcluded).sorted(), forKey: Keys.idleQuitExcluded)
            persistConfigurationIfReady()
        }
    }

    /// App identifiers excluded from quit-on-last-window-closed.
    @Published var windowQuitExcluded: Set<String> {
        didSet {
            defaults.set(Array(windowQuitExcluded).sorted(), forKey: Keys.windowQuitExcluded)
            persistConfigurationIfReady()
        }
    }

    @Published private(set) var perAppIdleMinutes: [String: Int] {
        didSet {
            persistPerAppIdleMinutes()
            persistConfigurationIfReady()
        }
    }

    private var legacyTogglesByName: [String: Bool]
    private var legacyIdleHoursByName: [String: Int]

    init(defaults: UserDefaults = .standard, configurationURL: URL? = nil) {
        self.defaults = defaults
        self.configurationURL = configurationURL ?? Self.defaultConfigurationURL()

        let persisted = Self.loadConfiguration(from: self.configurationURL)

        if let persisted {
            idleMinutes = Self.normalizedDuration(persisted.idleMinutes)
            showQuitButton = persisted.showQuitButton
            quitOnLastWindowClosed = persisted.quitOnLastWindowClosed
            warnBeforeQuitting = persisted.warnBeforeQuitting
            idleQuitExcluded = Set(persisted.idleQuitExcluded.filter(Self.isValidAppIdentifier))
            windowQuitExcluded = Set(persisted.windowQuitExcluded.filter(Self.isValidAppIdentifier))
            perAppIdleMinutes = persisted.perAppIdleMinutes.reduce(into: [:]) { result, item in
                guard Self.isValidAppIdentifier(item.key) else { return }
                result[item.key] = Self.normalizedDuration(item.value)
            }
        } else {
            if let minutes = defaults.object(forKey: Keys.idleMinutes) as? Int {
                idleMinutes = Self.normalizedDuration(minutes)
            } else if let hours = defaults.object(forKey: Keys.legacyHours) as? Int {
                idleMinutes = Self.normalizedDuration(hours * 60)
            } else {
                idleMinutes = IdleDuration.defaultMinutes
            }

            showQuitButton = defaults.bool(forKey: Keys.showQuitButton)
            quitOnLastWindowClosed = defaults.bool(forKey: Keys.quitOnLastWindowClosed)
            warnBeforeQuitting = defaults.object(forKey: Keys.warnBeforeQuitting) as? Bool ?? true
            idleQuitExcluded = Set(defaults.stringArray(forKey: Keys.idleQuitExcluded) ?? [])

            if let stored = defaults.stringArray(forKey: Keys.windowQuitExcluded) {
                windowQuitExcluded = Set(stored)
            } else {
                windowQuitExcluded = Self.defaultWindowQuitExcluded
            }

            if let data = defaults.data(forKey: Keys.perAppIdleMinutes),
               let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
                perAppIdleMinutes = stored.reduce(into: [:]) { result, item in
                    guard Self.isValidAppIdentifier(item.key) else { return }
                    result[item.key] = Self.normalizedDuration(item.value)
                }
            } else {
                perAppIdleMinutes = [:]
            }
        }

        if let data = defaults.data(forKey: Keys.legacyToggles),
           let toggles = try? JSONDecoder().decode([String: Bool].self, from: data) {
            legacyTogglesByName = toggles
        } else {
            legacyTogglesByName = [:]
        }

        if let data = defaults.data(forKey: Keys.legacyAppIdleHours),
           let hours = try? JSONDecoder().decode([String: Int].self, from: data) {
            legacyIdleHoursByName = hours
        } else {
            legacyIdleHoursByName = [:]
        }

        isInitializing = false
        syncDefaults()
        persistConfiguration()
    }

    static func defaultConfigurationURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MagicQuit", isDirectory: true)
            .appendingPathComponent("configuration.json", isDirectory: false)
    }

    var automaticConfigurationURL: URL { configurationURL }

    func migrateLegacyToggleIfNeeded(appName: String?, bundleId: String?) {
        guard let appName, let bundleId,
              let enabled = legacyTogglesByName.removeValue(forKey: appName) else { return }
        if !enabled { idleQuitExcluded.insert(bundleId) }
        persistLegacyToggles()
    }

    func migrateLegacyIdleDurationIfNeeded(appName: String?, bundleId: String?) {
        guard let appName, let bundleId,
              let hours = legacyIdleHoursByName.removeValue(forKey: appName) else { return }
        setIdleMinutesOverride(Self.normalizedDuration(hours * 60), forAppKey: bundleId)
        persistLegacyIdleHours()
    }

    func idleMinutes(forAppKey key: String?) -> Int {
        guard let key else { return idleMinutes }
        return perAppIdleMinutes[key] ?? idleMinutes
    }

    func idleMinutesOverride(forAppKey key: String?) -> Int? {
        guard let key else { return nil }
        return perAppIdleMinutes[key]
    }

    func setIdleMinutesOverride(_ minutes: Int?, forAppKey key: String?) {
        guard let key, Self.isValidAppIdentifier(key) else { return }
        if let minutes {
            perAppIdleMinutes[key] = Self.normalizedDuration(minutes)
        } else {
            perAppIdleMinutes.removeValue(forKey: key)
        }
    }

    func configurationDocument() -> MagicQuitConfiguration {
        MagicQuitConfiguration(
            version: MagicQuitConfiguration.currentVersion,
            idleMinutes: idleMinutes,
            showQuitButton: showQuitButton,
            quitOnLastWindowClosed: quitOnLastWindowClosed,
            warnBeforeQuitting: warnBeforeQuitting,
            idleQuitExcluded: idleQuitExcluded.sorted(),
            windowQuitExcluded: windowQuitExcluded.sorted(),
            perAppIdleMinutes: perAppIdleMinutes
        )
    }

    func applyConfiguration(_ document: MagicQuitConfiguration, merge: Bool = false) throws {
        try Self.validate(document)

        idleMinutes = document.idleMinutes
        showQuitButton = document.showQuitButton
        quitOnLastWindowClosed = document.quitOnLastWindowClosed
        warnBeforeQuitting = document.warnBeforeQuitting

        if merge {
            idleQuitExcluded.formUnion(document.idleQuitExcluded)
            windowQuitExcluded.formUnion(document.windowQuitExcluded)
            var overrides = perAppIdleMinutes
            overrides.merge(document.perAppIdleMinutes) { _, imported in imported }
            perAppIdleMinutes = overrides
        } else {
            idleQuitExcluded = Set(document.idleQuitExcluded)
            windowQuitExcluded = Set(document.windowQuitExcluded)
            perAppIdleMinutes = document.perAppIdleMinutes
        }
        persistConfiguration()
    }

    func decodeConfiguration(data: Data) throws -> MagicQuitConfiguration {
        guard data.count <= Self.maximumConfigurationBytes else {
            throw ConfigurationError.fileTooLarge(data.count)
        }
        let document = try JSONDecoder().decode(MagicQuitConfiguration.self, from: data)
        try Self.validate(document)
        return document
    }

    func resetToDefaults() {
        idleMinutes = IdleDuration.defaultMinutes
        showQuitButton = false
        quitOnLastWindowClosed = false
        warnBeforeQuitting = true
        idleQuitExcluded = []
        windowQuitExcluded = Self.defaultWindowQuitExcluded
        perAppIdleMinutes = [:]
    }

    private static func validate(_ document: MagicQuitConfiguration) throws {
        guard document.version == MagicQuitConfiguration.currentVersion else {
            throw ConfigurationError.unsupportedVersion(document.version)
        }
        guard IdleDuration.stepsInMinutes.contains(document.idleMinutes) else {
            throw ConfigurationError.unsupportedDuration(document.idleMinutes)
        }
        let identifiers = document.idleQuitExcluded + document.windowQuitExcluded + Array(document.perAppIdleMinutes.keys)
        guard identifiers.count <= maximumAppEntries else {
            throw ConfigurationError.tooManyEntries(identifiers.count)
        }
        var seen = Set<String>()
        for identifier in identifiers {
            guard isValidAppIdentifier(identifier) else {
                throw ConfigurationError.invalidAppIdentifier(identifier)
            }
            _ = seen.insert(identifier)
        }
        for minutes in document.perAppIdleMinutes.values where !IdleDuration.stepsInMinutes.contains(minutes) {
            throw ConfigurationError.unsupportedDuration(minutes)
        }
    }

    private static func isValidAppIdentifier(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 1_024 && !trimmed.contains("\0")
    }

    private static func normalizedDuration(_ minutes: Int) -> Int {
        IdleDuration.stepAtLeast(minutes: max(minutes, 1))
    }

    private static func loadConfiguration(from url: URL) -> MagicQuitConfiguration? {
        guard let data = try? Data(contentsOf: url), data.count <= maximumConfigurationBytes,
              let document = try? JSONDecoder().decode(MagicQuitConfiguration.self, from: data),
              document.version == MagicQuitConfiguration.currentVersion else { return nil }
        return document
    }

    private func syncDefaults() {
        defaults.set(idleMinutes, forKey: Keys.idleMinutes)
        defaults.set(showQuitButton, forKey: Keys.showQuitButton)
        defaults.set(quitOnLastWindowClosed, forKey: Keys.quitOnLastWindowClosed)
        defaults.set(warnBeforeQuitting, forKey: Keys.warnBeforeQuitting)
        defaults.set(idleQuitExcluded.sorted(), forKey: Keys.idleQuitExcluded)
        defaults.set(windowQuitExcluded.sorted(), forKey: Keys.windowQuitExcluded)
        persistPerAppIdleMinutes()
    }

    private func persistConfigurationIfReady() {
        guard !isInitializing else { return }
        persistConfiguration()
    }

    private func persistConfiguration() {
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configurationDocument())
            try data.write(to: configurationURL, options: [.atomic])
        } catch {
            // UserDefaults remains a compatibility fallback if the mirror cannot be written.
        }
    }

    private func persistLegacyToggles() {
        if legacyTogglesByName.isEmpty {
            defaults.removeObject(forKey: Keys.legacyToggles)
        } else if let data = try? JSONEncoder().encode(legacyTogglesByName) {
            defaults.set(data, forKey: Keys.legacyToggles)
        }
    }

    private func persistPerAppIdleMinutes() {
        if perAppIdleMinutes.isEmpty {
            defaults.removeObject(forKey: Keys.perAppIdleMinutes)
        } else if let data = try? JSONEncoder().encode(perAppIdleMinutes) {
            defaults.set(data, forKey: Keys.perAppIdleMinutes)
        }
    }

    private func persistLegacyIdleHours() {
        if legacyIdleHoursByName.isEmpty {
            defaults.removeObject(forKey: Keys.legacyAppIdleHours)
        } else if let data = try? JSONEncoder().encode(legacyIdleHoursByName) {
            defaults.set(data, forKey: Keys.legacyAppIdleHours)
        }
    }
}
