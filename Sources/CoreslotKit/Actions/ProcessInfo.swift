import Darwin
import Foundation

/// What the kernel says about the process at a pid.
public struct ProcessFacts: Sendable, Equatable {
    /// `proc_pidpath`: the file the process runs.
    public let executable: URL
    /// `pbi_start_tvsec`: when the process started, in whole seconds since the epoch.
    public let startSeconds: Int64
    /// `KERN_PROCARGS2`: the process's own arguments, the first one included.
    public let arguments: [String]

    public init(executable: URL, startSeconds: Int64, arguments: [String]) {
        (self.executable, self.startSeconds, self.arguments) = (executable, startSeconds, arguments)
    }
}

public protocol ProcessInspector: Sendable {
    /// Nil when any of the facts cannot be read.
    func facts(_ pid: pid_t) -> ProcessFacts?
}

/// Reads the facts from the kernel, which a process cannot change for another process.
public struct DarwinProcessInspector: ProcessInspector {
    public init() {}

    public func facts(_ pid: pid_t) -> ProcessFacts? {
        guard pid >= 2, let before = Self.startSeconds(pid) else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, let arguments = Self.arguments(pid),
              // The same start time on both sides: the path and arguments are of one process.
              Self.startSeconds(pid) == before
        else { return nil }
        let executable = URL(filePath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        return ProcessFacts(executable: executable, startSeconds: before, arguments: arguments)
    }

    private static func startSeconds(_ pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int64(clamping: info.pbi_start_tvsec)
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(buffer[0..<min(size, buffer.count)])
    }

    /// `KERN_PROCARGS2`'s layout: `argc` as a 32-bit integer, the exec path, NUL padding, then
    /// `argc` NUL-terminated arguments (the environment follows). Nil when it is cut short.
    static func parseProcArgs(_ b: ArraySlice<UInt8>) -> [String]? {
        guard b.count >= 4 else { return nil }
        let argc = b.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = b.startIndex + 4
        while i < b.endIndex, b[i] != 0 { i += 1 }
        while i < b.endIndex, b[i] == 0 { i += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc) {
            guard i < b.endIndex, let end = b[i...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: b[i..<end], as: UTF8.self))
            i = end + 1
        }
        return arguments
    }
}
