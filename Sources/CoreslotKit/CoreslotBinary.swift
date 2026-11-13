import Darwin
import Foundation

/// A coreslot release, `X.Y.Z`, or `.development` for a `0.0.0-…` build from a checkout.
public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let isDevelopment: Bool

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.init(major, minor, patch, isDevelopment: false)
    }

    private init(_ major: Int, _ minor: Int, _ patch: Int, isDevelopment: Bool) {
        (self.major, self.minor, self.patch, self.isDevelopment) = (major, minor, patch, isDevelopment)
    }

    public static let development = Version(0, 0, 0, isDevelopment: true)

    /// The oldest coreslot whose `status --json` has every key the app reads.
    public static let minimum = Version(0, 8, 0)

    /// `0.8.0`; a suffix after `-` or `+` is ignored, except that any `0.0.0` is a development build.
    public init?(_ text: String) {
        let core = text.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let x = Int(parts[0]), let y = Int(parts[1]), let z = Int(parts[2]),
              x >= 0, y >= 0, z >= 0
        else { return nil }
        self = x == 0 && y == 0 && z == 0 ? .development : Version(x, y, z)
    }

    /// Parses the line `coreslot version` prints, `coreslot <v> (protocol formats: <list>)`, the list
    /// digits, commas and spaces with a digit at least, as coreslot's own test pins it (the app never
    /// reads it); nil for any other.
    public static func parse(versionLine line: String) -> Version? {
        let w = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard w.count == 5, w[0] == "coreslot", w[2] == "(protocol", w[3] == "formats:", w[4].hasSuffix(")"),
              case let list = w[4].dropLast(), list.allSatisfy({ ", 0123456789".contains($0) }), list.contains(where: \.isWholeNumber)
        else { return nil }
        return Version(String(w[1]))
    }

    public static func < (a: Version, b: Version) -> Bool {
        (a.major, a.minor, a.patch, a.isDevelopment ? 0 : 1) < (b.major, b.minor, b.patch, b.isDevelopment ? 0 : 1)
    }

    public var description: String { isDevelopment ? "development build" : "\(major).\(minor).\(patch)" }
}

/// A `coreslot` executable and the release it says it is.
public struct CoreslotBinary: Sendable, Equatable {
    public let url: URL
    public let version: Version
    /// The file's `StatusSource.identity` when it was read: the same file overwritten in place is another binary.
    public var identity: [Int64] = []

    public init(url: URL, version: Version) {
        (self.url, self.version) = (url, version)
    }

    /// Runs `coreslot version` at `url`; nil when it does not answer with a version line.
    public static func probe(
        _ url: URL, environment: [String: String]?, runner: Runner = .process, timeout: Duration = .seconds(5)
    ) async -> CoreslotBinary? {
        let r = await runner.run(url, ["version"], environment: environment, timeout: timeout)
        guard r.exitCode == 0, !r.timedOut,
              let version = Version.parse(versionLine: String(decoding: r.stdout, as: UTF8.self))
        else { return nil }
        return CoreslotBinary(url: url, version: version)
    }
}

public enum Locate {
    /// The first `coreslot` that is an executable regular file, symlinks followed: `override`
    /// itself, then `directories`, then each absolute entry of `path` (the app's own `PATH`).
    public static func find(override: URL?, directories: [URL], path: String?) -> URL? {
        let fromPath = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        let candidates = [override].compactMap { $0 }
            + (directories + fromPath).map { $0.appending(path: "coreslot", directoryHint: .notDirectory) }
        return candidates.first(where: isExecutableFile)
    }

    /// `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
    public static var standardDirectories: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
        ]
    }

    /// The configuration file of a `coreslot` run with `environment`, by coreslot's rule: `config.toml`
    /// in a non-empty `CORESLOT_STATE_DIR`, else `.config/coreslot/config.toml` in the home the
    /// password database gives, never `$HOME`.
    public static func configFile(environment: [String: String]) -> String {
        if let dir = environment["CORESLOT_STATE_DIR"], !dir.isEmpty { return (dir as NSString).appendingPathComponent("config.toml") }
        return (getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "~") + "/.config/coreslot/config.toml"
    }

    static func isExecutableFile(_ url: URL) -> Bool {
        var st = stat()
        // stat follows symlinks; a directory named coreslot is executable too, and is not one.
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
