import Foundation

/// The app's fixed English for coreslot's closed codes. Text from coreslot inside a sentence goes
/// through `SafeText`.
public enum Words {
    /// The watchdog's level in words. An empty level is no sample in the last 6 s, which is idle
    /// while no hold is live.
    public static func level(_ doc: StatusDocument) -> String {
        let w = doc.watch, live = !doc.holds.isEmpty
        switch w.level {
        case "": return live ? "No recent reading" : "Idle"
        case "unknown": return "Memory reading failed"
        case "green": return w.learning > 0 && live ? "Learning" : "Memory normal"
        case "yellow": return "Memory tight"
        case "red" where w.protecting: return "Stopping commands"
        case "red": return "Memory very tight" + (w.reason.isEmpty ? "" : " · not stopping: " + SafeText.display(w.reason))
        case "floor": return "Memory critically low"
        case let code: return "Memory level " + SafeText.display(code)
        }
    }

    /// The sentence a notice adds to the header.
    public static func notice(_ notice: Notice) -> String {
        switch notice {
        case .tooOld: "Update coreslot to \(Version.minimum) or later"
        case .degraded(let reason): "coreslot is degraded: \(SafeText.display(reason))"
        case .configError(let error): "coreslot's configuration has a problem: \(SafeText.display(error))"
        case .formatNotUnderstood(let error):
            "This coreslot does not understand the state directory's format: update or repair coreslot"
                + (error.isEmpty ? "" : " (\(SafeText.display(error)))")
        case .schema(let n) where n > 1: "This coreslot's status document is newer than this app"
        case .schema: "This coreslot's status document has a schema this app does not know"
        }
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
        return ageS > 5 ? "\(text) · \(Formatting.duration(Double(ageS))) ago" : text
    }

    /// The one state shown when there is no document, and what to do about it.
    public static func problem(_ problem: Problem) -> (state: String, fix: String) {
        switch problem {
        case .notFound:
            ("coreslot was not found", "Install coreslot \(Version.minimum) or later in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.")
        case .stateUnreadable:
            ("coreslot cannot read its state", "Run coreslot doctor in a terminal to see why.")
        case .failed(let code):
            ("coreslot status failed with exit status \(code)", "Run coreslot doctor in a terminal to see why.")
        case .malformed:
            ("coreslot printed a status this app cannot read", "Run coreslot doctor, or update this app.")
        case .timedOut:
            ("coreslot status did not answer in time", "The next reading tries again; coreslot doctor can say what is slow.")
        }
    }

    /// The line under a hold that shows no stop button. `processChecked` is false when the app
    /// could not read the hold's process, which `status` does not report.
    public static func quietLine(container: Bool, processChecked: Bool) -> String {
        if container { return "Container work: stop the container" }
        return processChecked ? "Stop it where it was started" : "This process could not be checked"
    }
}
