import CoreslotKit
import os

/// The app's own log, in the unified log: transitions and actions at `.notice`, failures at
/// `.error`, the levels the system keeps. Every line is the app's own words and facts, with text
/// from the state directory passed through `SafeText.display`; no process's arguments, ever.
enum Log {
    private static let subsystem = "io.github.core-slot.menubar"
    static let status = Logger(subsystem: subsystem, category: "status")
    static let actions = Logger(subsystem: subsystem, category: "actions")
    static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

extension Logger {
    func say(_ line: LogLine) { line.failure ? error("\(line.text, privacy: .public)") : notice("\(line.text, privacy: .public)") }

    func say(_ text: String, failure: Bool = false) { say(LogLine(text: text, failure: failure)) }
}
