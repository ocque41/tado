import Foundation

/// Append-only NDJSON persister for `TadoEvent`s. One line per event,
/// fsynced through `AtomicStore.appendLine` so a crash between
/// fire-and-fsync loses at most the in-flight line (never corrupts
/// prior lines).
///
/// Writes are serialized on a dedicated background queue so the main
/// thread never blocks on disk I/O. Rotation (`current.ndjson` →
/// `archive/events-YYYY-MM-DD.ndjson.gz`) is triggered lazily on
/// append when the file's mtime day differs from "today" in UTC.
///
/// The NDJSON encoder intentionally does NOT pretty-print or sort
/// keys — one compact line per event is the whole point.
final class EventPersister {
    private let queue = DispatchQueue(label: "com.tado.events.persister", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // No pretty-printing, no sortedKeys — compact lines only.
        return e
    }()

    /// Append `event` to `events/current.ndjson`, rotating first if
    /// the current file belongs to an earlier UTC day.
    func append(_ event: TadoEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded()
            guard let data = try? self.encoder.encode(event),
                  let line = String(data: data, encoding: .utf8) else { return }
            try? AtomicStore.appendLine(line, to: StorePaths.eventsCurrent)
        }
    }

    // MARK: - Rotation

    private var lastRotationCheckDay: String?

    /// If `current.ndjson`'s mtime day ≠ today (UTC), gzip it into
    /// `archive/events-YYYY-MM-DD.ndjson.gz` and start fresh.
    ///
    /// Best-effort: any failure leaves the current file in place so
    /// appends still work. Keeps a per-run cache of "today's day
    /// string" so the fs stat only runs on UTC midnight rollover.
    private func rotateIfNeeded() {
        let today = Self.dayString(from: Date())
        if lastRotationCheckDay == today { return }
        lastRotationCheckDay = today

        let current = StorePaths.eventsCurrent
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else { return }

        guard let attrs = try? fm.attributesOfItem(atPath: current.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        let fileDay = Self.dayString(from: mtime)
        guard fileDay != today else { return }

        // Ship the old file to archive/events-YYYY-MM-DD.ndjson
        // (uncompressed — compression is a follow-up nice-to-have; the
        // point today is "old events don't clog the tail").
        let archiveURL = StorePaths.eventsArchiveDir
            .appendingPathComponent("events-\(fileDay).ndjson")

        do {
            try fm.createDirectory(at: StorePaths.eventsArchiveDir,
                                   withIntermediateDirectories: true)
            // If an archive for this day already exists (repeated
            // rotation attempts on the same day), concatenate.
            if fm.fileExists(atPath: archiveURL.path) {
                let head = try Data(contentsOf: archiveURL)
                let tail = try Data(contentsOf: current)
                try (head + tail).write(to: archiveURL, options: .atomic)
                try fm.removeItem(at: current)
            } else {
                try fm.moveItem(at: current, to: archiveURL)
            }
        } catch {
            NSLog("[EventPersister] rotation failed: \(error)")
        }
    }

    private static func dayString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
