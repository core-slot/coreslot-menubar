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

    /// Parses the line `coreslot version` prints, `coreslot <v> (protocol formats: <list>)`.
    public static func parse(versionLine line: String) -> (version: Version, formats: [Int])? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "coreslot ", mid = " (protocol formats: "
        guard line.hasPrefix(head), line.hasSuffix(")"), let m = line.range(of: mid),
              let version = Version(String(line[line.index(line.startIndex, offsetBy: head.count)..<m.lowerBound]))
        else { return nil }
        let list = line[m.upperBound..<line.index(before: line.endIndex)].split(separator: ",")
        let formats = list.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !formats.isEmpty, formats.count == list.count else { return nil }
        return (version, formats)
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
    public let protocolFormats: [Int]

    public init(url: URL, version: Version, protocolFormats: [Int] = []) {
        (self.url, self.version, self.protocolFormats) = (url, version, protocolFormats)
    }

    /// Runs `coreslot version` at `url`; nil when it does not answer with a version line.
    public static func probe(
        _ url: URL, environment: [String: String]?, runner: Runner = .process, timeout: Duration = .seconds(5)
    ) async -> CoreslotBinary? {
        let r = await runner.run(url, ["version"], environment: environment, timeout: timeout)
        guard r.exitCode == 0, !r.timedOut,
              let (version, formats) = Version.parse(versionLine: String(decoding: r.stdout, as: UTF8.self))
        else { return nil }
        return CoreslotBinary(url: url, version: version, protocolFormats: formats)
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

    static func isExecutableFile(_ url: URL) -> Bool {
        var st = stat()
        // stat follows symlinks; a directory named coreslot is executable too, and is not one.
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
