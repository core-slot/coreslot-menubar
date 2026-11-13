import Foundation

/// Text from the state directory or a process, shown escaped, never applied.
package enum SafeText {
    /// A backslash as `\\`, and every control, format (bidirectional, zero-width, tag), line or
    /// paragraph separator, unassigned or default-ignorable scalar (which renders as nothing) as
    /// `\u{XXXX}`, so two distinct strings stay distinct.
    package static func display(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\\" {
                out.append(contentsOf: #"\\"#.unicodeScalars)
                continue
            }
            let hidden: [Unicode.GeneralCategory] = [.control, .format, .lineSeparator, .paragraphSeparator, .unassigned]
            if hidden.contains(u.properties.generalCategory) || u.properties.isDefaultIgnorableCodePoint {
                let hex = String(u.value, radix: 16, uppercase: true)
                out.append(contentsOf: "\\u{\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex)}".unicodeScalars)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }
}
