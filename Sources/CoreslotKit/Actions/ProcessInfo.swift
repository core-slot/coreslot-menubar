import Darwin
import Foundation

/// What the kernel says about the process at a pid.
public struct ProcessFacts: Sendable, Equatable {
    /// The file the process runs, as the kernel maps it: no path renamed or linked since changes it.
    public let executable: FileID
    /// `pbi_start_tvsec`: when the process started, in whole seconds since the epoch.
    public let startSeconds: Int64
    /// `KERN_PROCARGS2`: the process's own arguments, the first one included.
    public let arguments: [String]

    public init(executable: FileID, startSeconds: Int64, arguments: [String]) {
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
        guard let executable = Self.executable(pid), let arguments = Self.arguments(pid),
              // The same start time on both sides: the file and arguments are of one process.
              Self.startSeconds(pid) == before
        else { return nil }
        return ProcessFacts(executable: executable, startSeconds: before, arguments: arguments)
    }

    /// The vnode of the lowest mapping, the main executable's text (a 64-bit process's
    /// `__PAGEZERO` maps nothing): `PROC_PIDREGIONPATHINFO` from address 0.
    private static func executable(_ pid: pid_t) -> FileID? {
        var r = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, 0, &r, size) == size,
              r.prp_prinfo.pri_protection & UInt32(VM_PROT_EXECUTE) != 0, r.prp_vip.vip_vi.vi_stat.vst_ino != 0
        else { return nil }
        let st = r.prp_vip.vip_vi.vi_stat
        return FileID(device: Int64(Int32(bitPattern: st.vst_dev)), inode: st.vst_ino)
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

    /// `KERN_PROCARGS2`'s layout: `argc` as a 32-bit integer, the exec path, NULs padding it to a
    /// multiple of 8 bytes, then `argc` NUL-terminated arguments (the environment follows). Nil
    /// when it is cut short, or when NULs run past the padding: then empty arguments begin it, and
    /// how many cannot be told.
    static func parseProcArgs(_ b: ArraySlice<UInt8>) -> [String]? {
        guard b.count >= 4 else { return nil }
        let argc = b.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = b.startIndex + 4
        while i < b.endIndex, b[i] != 0 { i += 1 }
        let padded = b.startIndex + 4 + (i - b.startIndex - 4) / 8 * 8 + 8
        while i < b.endIndex, b[i] == 0 { i += 1 }
        guard i <= padded else { return nil }
        var arguments: [String] = []
        while arguments.count < Int(argc) {
            guard i < b.endIndex, let end = b[i...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: b[i..<end], as: UTF8.self))
            i = end + 1
        }
        return arguments
    }
}
