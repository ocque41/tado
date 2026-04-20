import Foundation

enum AtomicStoreError: Error {
    case lockFailed(Int32)
    case writeFailed(Error)
    case renameFailed(Error)
    case readFailed(Error)
    case notFound(URL)
}

/// File-based canonical store with atomic writes + POSIX advisory
/// locking. One helper used by Swift, CLI shell tools, and bash
/// hooks — all go through the same lock discipline so the app,
/// `tado-config`, and eternal hooks cannot tear each other's writes.
///
/// Write protocol:
///   1. open-or-create "<target>.lock" with `flock(LOCK_EX)`
///   2. write "<target>.tmp" with fsync
///   3. rename "<target>.tmp" → "<target>" (POSIX-atomic)
///   4. release lock
///
/// Readers tolerate partial-read-during-write because the rename is
/// atomic — they'll either see the old or new full file. Shared locks
/// are available for read-mostly config paths that want strict serial
/// ordering vs. writers.
enum AtomicStore {
    // MARK: - Public: read

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .uncached)
        } catch {
            let nserr = error as NSError
            if nserr.code == NSFileReadNoSuchFileError { throw AtomicStoreError.notFound(url) }
            throw AtomicStoreError.readFailed(error)
        }
    }

    static func readIfExists(_ url: URL) -> Data? {
        (try? read(url))
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try read(url)
        return try jsonDecoder.decode(T.self, from: data)
    }

    // MARK: - Public: write

    /// Atomic write with exclusive lock. Creates parent directory if
    /// needed. Fsyncs before rename so a power loss after rename means
    /// the target is fully on disk.
    static func write(_ data: Data, to url: URL) throws {
        try ensureParent(url)
        let lockURL = lockURL(for: url)
        let tmpURL = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")

        let lockFD = try openLock(lockURL)
        defer { close(lockFD) }

        try withExclusiveLock(lockFD) {
            try writeAndFsync(data, to: tmpURL)
            try rename(from: tmpURL, to: url)
        }
    }

    static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        try write(data, to: url)
    }

    /// Append a single line to a file under an exclusive lock. Used
    /// by the event persister for NDJSON log lines. Creates the file
    /// if missing; does NOT rename (appends are serialized by the
    /// lock, and partial appends can't interleave because we hold the
    /// lock for the whole write).
    static func appendLine(_ line: String, to url: URL) throws {
        try ensureParent(url)
        let lockFD = try openLock(lockURL(for: url))
        defer { close(lockFD) }
        try withExclusiveLock(lockFD) {
            let payload = (line.hasSuffix("\n") ? line : line + "\n").data(using: .utf8) ?? Data()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: payload)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                try handle.synchronize()
                try handle.close()
            }
        }
    }

    // MARK: - Shared codecs

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Private

    private static func ensureParent(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func lockURL(for url: URL) -> URL {
        url.appendingPathExtension("lock")
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        try ensureParent(url)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 { throw AtomicStoreError.lockFailed(errno) }
        return fd
    }

    private static func withExclusiveLock(_ fd: Int32, _ body: () throws -> Void) throws {
        if flock(fd, LOCK_EX) != 0 { throw AtomicStoreError.lockFailed(errno) }
        defer { _ = flock(fd, LOCK_UN) }
        try body()
    }

    private static func writeAndFsync(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AtomicStoreError.writeFailed(error)
        }
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            _ = fsync(fd)
            close(fd)
        }
    }

    private static func rename(from src: URL, to dst: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: src)
            } else {
                try FileManager.default.moveItem(at: src, to: dst)
            }
        } catch {
            throw AtomicStoreError.renameFailed(error)
        }
    }
}
