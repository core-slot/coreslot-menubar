import Foundation

/// Each label's colour, by order of first sight: a new label never repaints the others. A label
/// not seen for `forgetS`, the longest range shown, is forgotten.
package struct LabelColors: Sendable {
    static let forgetS: TimeInterval = 24 * 60 * 60

    private var colors: [String: (index: Int, seen: Date)] = [:]
    private var next = 0

    package init() {}

    package subscript(_ label: String) -> Int? { colors[label]?.index }

    /// The labels known, in colour order.
    package var labels: [String] { colors.sorted { $0.value.index < $1.value.index }.map(\.key) }

    /// The labels of one reading, seen at `now`; then those unseen for `forgetS` go.
    package mutating func see(_ labels: [String], at now: Date) {
        for label in labels {
            let index = colors[label]?.index ?? next
            if index == next { next += 1 }
            colors[label] = (index, now)
        }
        colors = colors.filter { now.timeIntervalSince($0.value.seen) < Self.forgetS }
    }
}
