import Foundation

/// Fixed idle-duration steps offered in Settings: one control, no unit picker.
enum IdleDuration {
    static let stepsInMinutes = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440, 2880]
    static let defaultMinutes = 120

    static func label(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours) h" : "\(hours)h \(mins)m"
    }

    /// Smallest step that is at least the given duration; used when migrating 1.x
    /// settings. Rounding up on purpose: apps must never quit earlier than the
    /// user configured. Durations beyond the largest step clamp to it.
    static func stepAtLeast(minutes: Int) -> Int {
        stepsInMinutes.first { $0 >= minutes } ?? stepsInMinutes.last ?? defaultMinutes
    }

    static func stepDown(from minutes: Int) -> Int {
        stepsInMinutes.last { $0 < minutes } ?? stepsInMinutes.first ?? minutes
    }

    static func stepUp(from minutes: Int) -> Int {
        stepsInMinutes.first { $0 > minutes } ?? stepsInMinutes.last ?? minutes
    }

    /// "42 min", "3 h", "1h 30m", "12 s" — menu countdown display.
    static func shortRemaining(seconds: Int) -> String {
        if seconds >= 3600 {
            let totalMinutes = seconds / 60
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return mins == 0 ? "\(hours) h" : "\(hours)h \(mins)m"
        }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(max(seconds, 0)) s"
    }
}
