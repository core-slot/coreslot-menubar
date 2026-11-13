import Foundation

/// The app's fixed English for coreslot's closed codes. Text from coreslot inside a sentence goes
/// through `SafeText`.
package enum Words {
    /// The watchdog's level in words. An empty level is no sample in the last 6 s, which is idle
    /// while no hold is live.
    package static func level(_ doc: StatusDocument) -> String {
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

    /// The sentence a notice adds to the header, and the log's words for it.
    package static func notice(_ notice: Notice) -> (header: String, log: String) {
        switch notice {
        case .tooOld: ("Update coreslot to \(Version.minimum) or later", "coreslot older than \(Version.minimum)")
        case .degraded(let r): ("coreslot is degraded: \(SafeText.display(r))", "degraded: " + SafeText.display(r))
        case .configError(let e): ("coreslot's configuration has a problem: \(SafeText.display(e))", "config error: " + SafeText.display(e))
        case .formatNotUnderstood(let e):
            ("This coreslot does not understand the state directory's format: update or repair coreslot"
                + (e.isEmpty ? "" : " (\(SafeText.display(e)))"), "format not understood: " + SafeText.display(e))
        case .schema(let n) where n > 1: ("This coreslot's status document is newer than this app", "schema \(n)")
        case .schema(let n): ("This coreslot's status document has a schema this app does not know", "schema \(n)")
        }
    }

    /// Why a ticket waits, from its run's latest `waiting` line; nil for a code this app does not
    /// know. `ageS` is the line's age; past 5 s it is said.
    package static func reason(_ w: EventLine.Waiting, needMiB: Int64, realMemory: Bool, ageS: Int64) -> String? {
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
        case "watch_spacing": text = "Starting one at a time after memory pressure"
        case let code: guard let name = reasonName(code) else { return nil }; text = name
        }
        return ageS > 5 ? "\(text) · \(Formatting.duration(Double(ageS))) ago" : text
    }

    /// The reasons this app knows, in the legend's order: the key (every restart reason is
    /// `restart_`) and the name, which `reason` also says where it has no figures to add.
    package static let reasons: [(key: String, name: String)] = [
        ("room_short", "Not enough free memory"), ("behind_head", "Behind the first in line"),
        ("behind_ticket", "Waits its turn"), ("section_busy", "Waiting for the queue"), ("watch_level", "Memory is tight"),
        ("watch_spacing", "One at a time after memory pressure"), ("restart_", "Restarting after a memory stop"),
    ]

    /// A reason's name, for the timeline's legend; nil for a code this app does not know.
    package static func reasonName(_ code: String) -> String? {
        reasons.first(where: { $0.key == (code.hasPrefix("restart_") ? "restart_" : code) })?.name
    }

    /// The one state shown when there is no document, and what to do about it; `command` is the
    /// coreslot command that gave the problem.
    package static func problem(_ problem: Problem, command: String = "status") -> (state: String, fix: String) {
        switch problem {
        case .notFound:
            ("coreslot was not found", "Install coreslot \(Version.minimum) or later with brew install core-slot/tap/coreslot, or put it in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.")
        case .stateUnreadable:
            ("coreslot cannot read its state", "Run coreslot doctor in a terminal to see why.")
        case .failed(let code) where code < 0: // -errno: it could not be started or waited for
            ("coreslot \(command) could not be run (system error \(-code))", "The next reading tries again.")
        case .failed(let code):
            ("coreslot \(command) failed with exit status \(code)", "Run coreslot doctor in a terminal to see why.")
        case .malformed:
            ("coreslot printed a status this app cannot read", "Run coreslot doctor, or update this app.")
        case .timedOut:
            ("coreslot \(command) did not answer in time", "The next reading tries again; coreslot doctor can say what is slow.")
        }
    }

    /// The line under a hold that shows no stop button. `processChecked` is false when the app
    /// could not read the hold's process, which `status` does not report.
    package static func quietLine(container: Bool, processChecked: Bool) -> String {
        if container { return "Container work: stop the container" }
        return processChecked ? "Stop it where it was started" : "This process could not be checked"
    }
}
