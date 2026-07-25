import Foundation

/// Compatibility aliases for the existing settings UI and exported file name.
typealias TimingSettingsDocument = MagicQuitConfiguration

extension AppSettings {
    func timingSettingsDocument() -> TimingSettingsDocument {
        configurationDocument()
    }

    func applyTimingSettingsDocument(_ document: TimingSettingsDocument) throws {
        try applyConfiguration(document)
    }
}
