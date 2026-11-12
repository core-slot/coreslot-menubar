import Darwin
import Foundation

/// Reads the complete lines appended to one JSON-lines log and its older generation
/// (`samples.jsonl` and `samples.1.jsonl`), in bounded chunks, across rotation and truncation.
///
/// It holds no file open between calls: each read opens the files by path and compares the
/// device and inode it remembers, so a rotated file is finished by name as the older generation.
public struct JSONLTail: Sendable {
    /// How much of a file the first open reads at most.
    static let firstOpenWindow: Int64 = 64 << 20

    struct FileID: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    public let current: URL
    public let older: URL
    private let startingAfter: Date?
    private var opened = false
    private var file: FileID?
    private var offset: Int64 = 0
    /// The older generation, when it is to be read to its end before the current file.
    private var finishing: (id: FileID, offset: Int64)?
    private var held = Data()
    /// Bytes up to the next newline are dropped: a line cut by a start mid-file, or too long.
    private var skipping = false

    /// With `startingAfter`, the first open reads only what may be newer than that date; the
    /// caller drops older lines as it parses. Without it, both generations are read whole.
    public init(current: URL, older: URL, startingAfter: Date? = nil) {
        (self.current, self.older, self.startingAfter) = (current, older, startingAfter)
    }

    /// The logs of a state directory, each with its older generation.
    public enum Log: String, Sendable {
        case samples = "telemetry/samples", events = "telemetry/events", runs = "log/runs"
    }

    public init(stateDir: URL, log: Log, startingAfter: Date? = nil) {
        self.init(
            current: stateDir.appending(path: log.rawValue + ".jsonl"),
            older: stateDir.appending(path: log.rawValue + ".1.jsonl"), startingAfter: startingAfter)
    }

    /// The complete lines appended since the last call, at most `maxBytes` of them in all; an
    /// empty result means nothing more is there now. A last line without its newline is held.
    public mutating func read(maxBytes: Int) throws -> [Data] {
        precondition(maxBytes > 0)
        if !opened {
            try firstOpen()
            opened = true
        }
        while true {
            if let f = finishing {
                let chunk = try Self.chunk(older, expecting: f.id, at: f.offset, count: maxBytes - held.count)
                guard let chunk, !chunk.data.isEmpty else {
                    // The older generation is done, or gone: a line it left unfinished never ends.
                    finishing = nil
                    (held, skipping) = (Data(), false)
                    continue
                }
                finishing = (f.id, f.offset + Int64(chunk.data.count))
                let lines = split(chunk.data, maxBytes: maxBytes)
                if !lines.isEmpty { return lines }
                continue
            }
            guard let chunk = try Self.chunk(current, expecting: nil, at: offset, count: maxBytes - held.count)
            else {
                if let f = file { // rotated, and the new file is not there yet
                    finishing = (f, offset)
                    (file, offset) = (nil, 0)
                    continue
                }
                return []
            }
            if let f = file, f != chunk.id {
                finishing = (f, offset)
                (file, offset) = (nil, 0)
                continue
            }
            if file == nil {
                (file, offset) = (chunk.id, 0)
                (held, skipping) = (Data(), false)
                continue
            }
            if chunk.size < offset { // truncated: start again from 0
                offset = 0
                (held, skipping) = (Data(), false)
                continue
            }
            if chunk.data.isEmpty { return [] }
            offset += Int64(chunk.data.count)
            let lines = split(chunk.data, maxBytes: maxBytes)
            if !lines.isEmpty { return lines }
        }
    }

    private mutating func firstOpen() throws {
        guard let head = try Self.chunk(current, expecting: nil, at: 0, count: 0) else {
            if startingAfter == nil, let old = try Self.chunk(older, expecting: nil, at: 0, count: 0) {
                finishing = (old.id, 0)
            }
            return
        }
        let start = startingAfter == nil ? 0 : max(0, head.size - Self.firstOpenWindow)
        (file, offset, skipping) = (head.id, start, start > 0)
        guard start == 0, try needsOlder(head.id) else { return }
        if let old = try Self.chunk(older, expecting: nil, at: 0, count: 0) {
            let from = startingAfter == nil ? 0 : max(0, old.size - Self.firstOpenWindow)
            finishing = (old.id, from)
            skipping = from > 0
        }
    }

    /// The older generation may hold lines newer than the date unless the current file's first
    /// line is not newer than it; an empty or unreadable first line cannot say so.
    private func needsOlder(_ id: FileID) throws -> Bool {
        guard let after = startingAfter else { return true }
        guard let first = try Self.chunk(current, expecting: id, at: 0, count: 64 << 10),
              let end = first.data.firstIndex(of: 0x0a),
              let line = try? JSONDecoder().decode(Stamp.self, from: first.data[..<end])
        else { return true }
        return Double(line.timeNS) / 1e9 > after.timeIntervalSince1970
    }

    private struct Stamp: Decodable {
        let timeNS: Int64
        enum CodingKeys: String, CodingKey { case timeNS = "time_ns" }
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

    /// Up to `count` bytes of the file at `url` from `offset`, with its identity and size; nil
    /// when it does not exist, or is not the file `expecting` names.
    private static func chunk(_ url: URL, expecting: FileID?, at offset: Int64, count: Int)
        throws -> (id: FileID, size: Int64, data: Data)?
    {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let id = FileID(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
        if let expecting, expecting != id { return nil }
        let size = Int64(st.st_size)
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
