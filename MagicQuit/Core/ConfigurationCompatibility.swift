import Foundation

struct AppTimingSetting: Codable, Equatable {
    let appIdentifier: String
    let idleMinutes: Int
}

struct TimingSettingsDocument: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let defaultIdleMinutes: Int
    let apps: [AppTimingSetting]
    let showQuitButton: Bool?
    let quitOnLastWindowClosed: Bool?
    let warnBeforeQuitting: Bool?
    let idleQuitExcluded: [String]?
    let windowQuitExcluded: [String]?

    init(
        version: Int,
        defaultIdleMinutes: Int,
        apps: [AppTimingSetting],
        showQuitButton: Bool? = nil,
        quitOnLastWindowClosed: Bool? = nil,
        warnBeforeQuitting: Bool? = nil,
        idleQuitExcluded: [String]? = nil,
        windowQuitExcluded: [String]? = nil
    ) {
        self.version = version
        self.defaultIdleMinutes = defaultIdleMinutes
        self.apps = apps
        self.showQuitButton = showQuitButton
        self.quitOnLastWindowClosed = quitOnLastWindowClosed
        self.warnBeforeQuitting = warnBeforeQuitting
        self.idleQuitExcluded = idleQuitExcluded
        self.windowQuitExcluded = windowQuitExcluded
    }
}

enum TimingSettingsDocumentError: LocalizedError {
    case unsupportedVersion(Int)
    case unsupportedDuration(Int)
    case invalidAppIdentifier(String)
    case duplicateAppIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported configuration version: \(version)."
        case .unsupportedDuration(let minutes): "Unsupported idle duration: \(minutes) minutes."
        case .invalidAppIdentifier(let identifier): "Invalid app identifier: \(identifier)."
        case .duplicateAppIdentifier(let identifier): "Duplicate app identifier: \(identifier)."
        }
    }
}

extension AppSettings {
    func timingSettingsDocument() -> TimingSettingsDocument {
        TimingSettingsDocument(
            version: TimingSettingsDocument.currentVersion,
            defaultIdleMinutes: idleMinutes,
            apps: perAppIdleMinutes
                .filter { !$0.key.contains("/") }
                .map { AppTimingSetting(appIdentifier: $0.key, idleMinutes: $0.value) }
                .sorted { $0.appIdentifier < $1.appIdentifier },
            showQuitButton: showQuitButton,
            quitOnLastWindowClosed: quitOnLastWindowClosed,
            warnBeforeQuitting: warnBeforeQuitting,
            idleQuitExcluded: idleQuitExcluded.filter { !$0.contains("/") }.sorted(),
            windowQuitExcluded: windowQuitExcluded.filter { !$0.contains("/") }.sorted()
        )
    }

    func applyTimingSettingsDocument(_ document: TimingSettingsDocument) throws {
        guard document.version == 1 || document.version == TimingSettingsDocument.currentVersion else {
            throw TimingSettingsDocumentError.unsupportedVersion(document.version)
        }
        guard IdleDuration.stepsInMinutes.contains(document.defaultIdleMinutes) else {
            throw TimingSettingsDocumentError.unsupportedDuration(document.defaultIdleMinutes)
        }

        var overrides: [String: Int] = [:]
        for app in document.apps {
            let identifier = app.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier.count <= 1_024,
                  !identifier.contains("\0"), !identifier.contains("/") else {
                throw TimingSettingsDocumentError.invalidAppIdentifier(app.appIdentifier)
            }
            guard IdleDuration.stepsInMinutes.contains(app.idleMinutes) else {
                throw TimingSettingsDocumentError.unsupportedDuration(app.idleMinutes)
            }
            guard overrides[identifier] == nil else {
                throw TimingSettingsDocumentError.duplicateAppIdentifier(identifier)
            }
            overrides[identifier] = app.idleMinutes
        }

        try applyConfiguration(MagicQuitConfiguration(
            version: MagicQuitConfiguration.currentVersion,
            idleMinutes: document.defaultIdleMinutes,
            showQuitButton: document.showQuitButton ?? showQuitButton,
            quitOnLastWindowClosed: document.quitOnLastWindowClosed ?? quitOnLastWindowClosed,
            warnBeforeQuitting: document.warnBeforeQuitting ?? warnBeforeQuitting,
            idleQuitExcluded: document.idleQuitExcluded ?? idleQuitExcluded.sorted(),
            windowQuitExcluded: document.windowQuitExcluded ?? windowQuitExcluded.sorted(),
            perAppIdleMinutes: overrides
        ))
    }
}
