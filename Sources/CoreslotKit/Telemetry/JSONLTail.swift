import Darwin
import Foundation

/// Reads the complete lines appended to one JSON-lines log and its older generation
/// (`samples.jsonl` and `samples.1.jsonl`), in bounded chunks, across rotation and truncation.
///
/// It holds no file open between calls: each read opens the files by path and compares the
/// device and inode it remembers, so a rotated file is finished by name as the older generation.
package struct JSONLTail: Sendable {
    /// How much of the two generations, taken as one, the first read takes at most.
    static let firstOpenWindow: Int64 = 64 << 20

    package let current: URL
    package let older: URL
    private var opened = false
    private var file: FileID?
    /// Where the current file is read next; 0 while `file` is nil.
    private(set) var offset: Int64 = 0
    /// The older generation, when it is to be read to its end before the current file.
    private var finishing: (id: FileID, offset: Int64)?
    private var held = Data()
    /// Bytes up to the next newline are dropped: a line cut by a start mid-file, or too long.
    private var skipping = false
    /// True when the last `read` reached the end of what is there now; false, call again.
    package private(set) var atEnd = false

    /// The first read starts `firstOpenWindow` bytes before the end of the older generation and
    /// the current file taken as one; the caller drops lines older than it wants as it parses.
    package init(current: URL, older: URL) {
        (self.current, self.older) = (current, older)
    }

    /// The logs of a state directory, each with its older generation.
    package enum Log: String, Sendable {
        case samples = "telemetry/samples", events = "telemetry/events", runs = "log/runs"
    }

    package init(stateDir: URL, log: Log) {
        self.init(current: stateDir.appending(path: log.rawValue + ".jsonl"), older: stateDir.appending(path: log.rawValue + ".1.jsonl"))
    }

    /// Complete lines appended since the last call, at most `maxBytes` of them in all, from at most
    /// `maxBytes` bytes read. No lines with `atEnd` false means: call again. A last line without
    /// its newline is held; a line longer than `maxBytes` is skipped.
    package mutating func read(maxBytes: Int) throws -> [Data] {
        precondition(maxBytes > 0)
        if !opened {
            try firstOpen()
            opened = true
        }
        var budget = maxBytes
        atEnd = false
        while budget > 0 {
            let count = min(budget, maxBytes - held.count)
            if let f = finishing {
                guard let chunk = try Self.chunk(older, expecting: f.id, at: f.offset, count: count),
                      chunk.id == f.id, !chunk.data.isEmpty
                else {
                    // The older generation is done, or gone: a line it left unfinished never ends.
                    finishing = nil
                    (held, skipping) = (Data(), false)
                    continue
                }
                budget -= chunk.data.count
                finishing = (f.id, f.offset + Int64(chunk.data.count))
                let lines = split(chunk.data, maxBytes: maxBytes)
                if !lines.isEmpty { return lines }
                continue
            }
            guard let chunk = try Self.chunk(current, expecting: file, at: offset, count: count) else {
                if let f = file { // rotated, and the new file is not there yet
                    finishing = (f, offset)
                    (file, offset) = (nil, 0)
                    continue
                }
                atEnd = true
                return []
            }
            if let f = file, f != chunk.id { // rotated: nothing was read from the new file
                finishing = (f, offset)
                (file, offset) = (nil, 0)
                continue
            }
            if file == nil { (file, held, skipping) = (chunk.id, Data(), false) }
            if chunk.size < offset { // truncated: start again from 0
                offset = 0
                (held, skipping) = (Data(), false)
                continue
            }
            if chunk.data.isEmpty {
                atEnd = true
                return []
            }
            budget -= chunk.data.count
            offset += Int64(chunk.data.count)
            let lines = split(chunk.data, maxBytes: maxBytes)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    /// Places the start `firstOpenWindow` bytes before the end of the older generation and the
    /// current file taken as one, so the older one is read whenever the window reaches into it. A
    /// start inside a line skips to its end.
    private mutating func firstOpen() throws {
        let old = try Self.chunk(older, expecting: nil, at: 0, count: 0)
        let head = try Self.chunk(current, expecting: nil, at: 0, count: 0)
        let oldSize = old?.size ?? 0
        let start = max(0, oldSize + (head?.size ?? 0) - Self.firstOpenWindow)
        if let old, start < oldSize {
            finishing = (old.id, start)
            skipping = start > 0
        }
        if let head {
            (file, offset) = (head.id, max(0, start - oldSize))
            if finishing == nil { skipping = offset > 0 }
        }
    }

    /// Splits held bytes and `data` into complete lines; the rest is held. Returned lines add up
    /// to at most `maxBytes`, as `held` and `data` together do.
    private mutating func split(_ data: Data, maxBytes: Int) -> [Data] {
        var buffer = held
        buffer.append(data)
        held = Data()
        var lines: [Data] = []
        var start = buffer.startIndex
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            while start < buffer.endIndex {
                let from = start - buffer.startIndex
                guard let hit = memchr(base + from, 0x0a, raw.count - from) else { break }
                let end = buffer.startIndex + (base.distance(to: UnsafeRawPointer(hit)))
                if skipping {
                    skipping = false
                } else if end > start {
                    lines.append(Data(buffer[start..<end]))
                }
                start = end + 1
            }
        }
        if skipping { return lines }
        held = Data(buffer[start...])
        if held.count >= maxBytes { // a line longer than a whole chunk is dropped
            (held, skipping) = (Data(), true)
        }
        return lines
    }

    /// The identity and size of the regular file at `url`, and up to `count` bytes of it from
    /// `offset` when it is the file `expecting` names, or `expecting` is nil; nil when there is no
    /// regular file there. `O_NONBLOCK` keeps a FIFO from blocking the open, and is kept: it has
    /// no effect on reading a regular file.
    private static func chunk(_ url: URL, expecting: FileID?, at offset: Int64, count: Int)
        throws -> (id: FileID, size: Int64, data: Data)?
    {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard st.st_mode & S_IFMT == S_IFREG else { return nil }
        let id = FileID(st)
        let size = Int64(st.st_size)
        if let expecting, expecting != id { return (id, size, Data()) }
        let want = max(0, min(Int64(count), size - offset))
        var data = Data(count: Int(want))
        var got = 0
        try data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while got < Int(want) {
                let n = pread(fd, buf.baseAddress! + got, Int(want) - got, off_t(offset) + off_t(got))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if n == 0 { break }
                got += n
            }
        }
        data.removeSubrange(got...)
        return (id, size, data)
    }
}

/// A file by device and inode: the tail's rotation check, and the stop's executable check.
package struct FileID: Equatable, Sendable {
    let device: Int64
    let inode: UInt64

    init(device: Int64, inode: UInt64) { (self.device, self.inode) = (device, inode) }

    init(_ st: stat) { self.init(device: Int64(st.st_dev), inode: UInt64(st.st_ino)) }

    /// The file at `url`, symlinks followed; nil when there is none.
    package init?(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        self.init(st)
    }
}
