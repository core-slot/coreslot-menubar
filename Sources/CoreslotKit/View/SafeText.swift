import Foundation

/// Text from the state directory or a process, shown escaped, never applied.
public enum SafeText {
    /// A backslash as `\\`, and every control, format (bidirectional, zero-width, tag), line and
    /// paragraph separator scalar as `\u{XXXX}`, so two distinct strings stay distinct.
    public static func display(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\\" {
                out.append(contentsOf: #"\\"#.unicodeScalars)
                continue
            }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                let hex = String(u.value, radix: 16, uppercase: true)
                out.append(contentsOf: "\\u{\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex)}".unicodeScalars)
            default:
                out.append(u)
            }
        }
        return String(out)
    }
}
