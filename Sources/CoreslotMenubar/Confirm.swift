import AppKit
import CoreslotKit

/// The confirmations: a standard alert, outside the popover, with "Cancel" the default button.
/// They inform; the checks before a stop are in `CoreslotKit`.
@MainActor
enum Confirm {
    /// True when the person chose the alert's action.
    static func ask(_ alert: AlertText.Alert) -> Bool {
        #if DEBUG
        if let answer = Present.answer {
            Present.log("alert \(alert.title) | \(alert.message) | answered \(answer ? alert.confirm : "Cancel")")
            return answer
        }
        #endif
        let a = make(alert)
        NSApp.activate()
        return a.runModal() == .alertSecondButtonReturn
    }

    /// One sentence about what happened, with an OK button.
    static func tell(_ words: String) {
        #if DEBUG
        if Present.answer != nil { return Present.log("told \(words)") }
        #endif
        let a = make(words)
        NSApp.activate()
        a.runModal()
    }

    static func make(_ alert: AlertText.Alert) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = alert.title
        a.informativeText = alert.message
        a.addButton(withTitle: "Cancel") // the first button is the default; "Cancel" also takes Escape
        a.addButton(withTitle: alert.confirm).hasDestructiveAction = true
        return a
    }

    static func make(_ words: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = words
        a.addButton(withTitle: "OK")
        return a
    }
}
