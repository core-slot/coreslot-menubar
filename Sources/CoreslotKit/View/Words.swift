import Foundation

/// The app's fixed English for coreslot's closed codes. Text from coreslot inside a sentence goes
/// through `SafeText`.
public enum Words {
    /// The watchdog's level in words.
    public static func level(_ watch: StatusDocument.Watch) -> String {
        switch watch.level {
        case "green": watch.learning > 0 ? "Learning" : "Memory normal"
        case "yellow": "Memory tight"
        case "red": "Stopping commands"
        case "floor": "Memory critically low"
        default: "No recent reading"
        }
    }

    /// The sentence a notice adds to the header; nil for a development build, which needs none.
    public static func notice(_ notice: Notice) -> String? {
        switch notice {
        case .tooOld: "Update coreslot to \(Version.minimum) or later"
        case .development: nil
        case .degraded(let reason): "coreslot is degraded: \(SafeText.display(reason))"
        case .configError(let error): "coreslot's configuration has a problem: \(SafeText.display(error))"
        case .formatNotUnderstood: "This coreslot writes a format this app does not know"
        case .schema: "This coreslot's status document is newer than this app"
        }
    }

    /// The level, then each notice's sentence; the sentences alone for a schema-only document.
    public static func header(_ doc: StatusDocument, notices: [Notice]) -> String {
        ((doc.isSchemaOnly ? [] : [level(doc.watch)]) + notices.compactMap(notice)).joined(separator: " · ")
    }

    /// Why a ticket waits, from its run's latest `waiting` line; nil for a code this app does not
    /// know. `ageS` is the line's age; past 5 s it is said.
    public static func reason(_ w: EventLine.Waiting, needMiB: Int64, realMemory: Bool, ageS: Int64) -> String? {
        let text: String
        switch w.reason {
        case "room_short":
            let need = Formatting.size(needMiB)
            if let room = w.roomMiB {
                text = "Needs \(need), \(Formatting.size(room)) free" + (realMemory ? " on the machine" : "")
            } else {
                text = "Needs \(need), more than is free"
            }
        case "behind_head":
            text = w.noPass == "too_long" ? "Fits, but runs longer than the first in line waits"
                : "Fits, but behind the first in line"
        case "behind_ticket": text = "Waits its turn"
        case "section_busy": text = "Waiting for the queue"
        case "watch_level": text = "Memory is tight"
        case "watch_spacing": text = "Starting one at a time after memory pressure"
        case let r where r.hasPrefix("restart_"): text = "Restarting after a memory stop"
        default: return nil
        }
        return ageS > 5 ? "\(text) · \(Formatting.duration(ageS)) ago" : text
    }

    /// The line under a hold that shows no stop button. `processChecked` is false when the app
    /// could not read the hold's process, which `status` does not report.
    public static func quietLine(container: Bool, processChecked: Bool) -> String {
        if container { return "Container work: stop the container" }
        return processChecked ? "Stop it where it was started" : "This process could not be checked"
    }
}
