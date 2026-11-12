import Foundation

/// Numbers as the app writes them.
public enum Formatting {
    /// As coreslot prints a size: MiB below 1 GiB, else GiB to one decimal, a whole number bare.
    public static func size(_ mib: Int64) -> String {
        guard mib >= 1024 else { return "\(mib) MiB" }
        let tenths = mib / 1024 * 10 + (mib % 1024 * 10 + 512) / 1024
        return tenths % 10 == 0 ? "\(tenths / 10) GiB" : "\(tenths / 10).\(tenths % 10) GiB"
    }

    /// "59 s" below a minute, then to the nearest minute: "5 min", "2 h 5 min".
    public static func duration(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        let m = s / 60 + (s % 60 >= 30 ? 1 : 0)
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// A forecast: "≈ 5 min".
    public static func approximately(_ seconds: Int64) -> String { "≈ " + duration(seconds) }

    /// The first ticket's `expected_wait_s`: a 0 is not a promise that it starts now.
    public static func firstTicketWait(_ s: Int64?) -> String {
        guard let s else { return "no estimate" }
        return s > 0 ? "starts in " + approximately(s) : "next"
    }

    /// A hold's `left_s`.
    public static func timeLeft(_ s: Int64?) -> String {
        guard let s else { return "no estimate" }
        return s > 0 ? approximately(s) : "past its usual time"
    }
}
