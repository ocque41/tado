import Foundation

/// Mirror of `.tado/eternal/state.json` — written by the hook shell scripts,
/// read by the EternalDashboard on a 1 s polling timer.
///
/// The hooks are the source of truth; Swift only reads. Keeping this struct
/// permissive (optional sub-fields, tolerant JSON) so a malformed file from a
/// mid-write hook doesn't crash the UI — the next tick picks up a valid copy.
struct EternalState: Codable, Equatable {
    /// `"mega"` or `"sprint"`.
    var mode: String = "mega"
    /// Unix seconds. Runtime clock is derived locally — don't trust this for display.
    var startedAt: TimeInterval = 0
    /// Unix seconds. Updated by `post-tool.sh` and the marker branches of `stop.sh`.
    var lastActivityAt: TimeInterval = 0
    /// Total Stop-hook blocks. In Mega mode this is the big number; in Sprint mode
    /// it's the per-sprint work count (subordinate to `sprints`).
    var iterations: Int = 0
    /// Sprint mode only: total `[SPRINT-DONE]` markers seen by the Stop hook.
    var sprints: Int = 0
    /// Count of `SessionStart` "compact" hook firings.
    var compactions: Int = 0
    /// `working | evaluating | compacting | idle | completed | stopped`.
    var phase: String = "working"
    /// Tail of the most recent progress.md line — useful as a one-glance summary
    /// in the dashboard card.
    var lastProgressNote: String?
    /// Sprint mode: numeric or string metric from the last sprint. JSON `null`
    /// rehydrates as nil.
    var lastMetric: MetricValue?
    var completionMarker: String = "ETERNAL-DONE"
    /// Sprint mode only. Bracketed to discourage accidental false hits.
    var sprintMarker: String = "[SPRINT-DONE]"

    /// Runtime derived from `startedAt`. Zero while the eternal hasn't started.
    var runtime: TimeInterval {
        guard startedAt > 0 else { return 0 }
        let now = Date().timeIntervalSince1970
        return max(0, now - startedAt)
    }

    /// Seconds since the last hook wrote `lastActivityAt`. Used for "Ns ago"
    /// labels. Returns `nil` while the file has never been touched (startup
    /// edge case — the Swift spawn path seeds `lastActivityAt = startedAt`).
    var secondsSinceActivity: TimeInterval? {
        guard lastActivityAt > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        return max(0, now - lastActivityAt)
    }

    /// Phase pill colour class consumed by the dashboard. Kept here so the UI
    /// doesn't re-duplicate the string-to-enum dance.
    enum PhaseKind: String {
        case working, evaluating, compacting, idle, completed, stopped, unknown
    }

    var phaseKind: PhaseKind {
        PhaseKind(rawValue: phase) ?? .unknown
    }
}

/// Loose wrapper so `lastMetric` accepts the two shapes Claude is likely to emit
/// (a bare number, or a short label like "pass"). Either path roundtrips to
/// `.number` or `.text`; unknown JSON types fall back to `.text` of the
/// stringified payload.
enum MetricValue: Codable, Equatable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            self = .number(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .text(s)
            return
        }
        self = .text("")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .text(let s):   try c.encode(s)
        }
    }

    var display: String {
        switch self {
        case .number(let d):
            if d.rounded() == d && abs(d) < 1e12 {
                return String(Int(d))
            }
            return String(format: "%.3g", d)
        case .text(let s):
            return s
        }
    }

    var numberValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }
}

/// One row parsed from `.tado/eternal/metrics.jsonl`. Tolerant — missing or
/// malformed lines are filtered out by the parser, not surfaced as errors.
///
/// Two shapes are accepted in the wild:
///
/// - Minimal: `{sprint, timestamp, metric, note}` — written by older trials
///   and by architect scripts that only record the composite.
/// - Extended: adds `components: {name: number}` and `milestone: string`.
///   Modern `score.sh` scripts emit this so the dashboard can render a
///   per-dimension breakdown (build_clean, plan_coverage, …) without
///   needing a second file.
///
/// `components` is intentionally `[String: Double]` (not a fixed struct)
/// because rubrics differ per trial — `tado` has 9 Dispatch dimensions,
/// `gg` has 4 game dimensions. The UI renders whichever keys are present.
struct EternalMetricSample: Codable, Equatable, Identifiable {
    var sprint: Int
    var timestamp: String
    var metric: MetricValue
    var note: String?
    var components: [String: Double]?
    var milestone: String?

    var id: Int { sprint }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let reservedKeys: Set<String> = [
        "sprint", "sprint_n", "timestamp", "metric", "composite",
        "note", "notes", "components", "milestone",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        if let n = try c.decodeIfPresent(Int.self, forKey: AnyKey("sprint")) {
            sprint = n
        } else if let n = try c.decodeIfPresent(Int.self, forKey: AnyKey("sprint_n")) {
            sprint = n
        } else if let d = try c.decodeIfPresent(Double.self, forKey: AnyKey("sprint_n")) {
            sprint = Int(d)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey("sprint"), in: c,
                debugDescription: "missing sprint / sprint_n")
        }

        timestamp = (try? c.decode(String.self, forKey: AnyKey("timestamp"))) ?? ""

        if c.contains(AnyKey("metric")) {
            metric = try c.decode(MetricValue.self, forKey: AnyKey("metric"))
        } else if let d = try c.decodeIfPresent(Double.self, forKey: AnyKey("composite")) {
            metric = .number(d)
        } else {
            metric = .text("")
        }

        note = try c.decodeIfPresent(String.self, forKey: AnyKey("note"))
            ?? c.decodeIfPresent(String.self, forKey: AnyKey("notes"))

        milestone = try c.decodeIfPresent(String.self, forKey: AnyKey("milestone"))

        if let nested = try c.decodeIfPresent([String: Double].self, forKey: AnyKey("components")) {
            components = nested
        } else {
            var flat: [String: Double] = [:]
            for key in c.allKeys where !Self.reservedKeys.contains(key.stringValue) {
                if let d = try? c.decode(Double.self, forKey: key) { flat[key.stringValue] = d }
            }
            components = flat.isEmpty ? nil : flat
        }
    }
}
