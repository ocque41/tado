import Foundation

/// Hand-rolled line-granularity diff used by both User Notes (P4) and
/// Agent Notes (P5) Diff lenses. We avoid pulling in a Swift package
/// because the Eternal brief disallows new dependencies for the diff
/// engine, and a small LCS implementation is enough for the surface's
/// "show me what changed between two scope versions of one note" use
/// case.
///
/// The algorithm is the textbook dynamic-programming LCS over line
/// arrays: O(m·n) time, O(min(m,n)) backtrace via a length matrix —
/// trivially fast on the brief's 2 KB / ~50-line target. Each
/// `DiffLine` records its origin (left only / right only / common) so
/// the renderer can colour insertions and deletions without re-walking
/// the matrices.
enum DiffEngine {

    enum Origin: Equatable {
        case common
        case removedFromLeft
        case addedOnRight

        /// Human-readable label both User-Notes and Agent-Notes diff
        /// lenses prepend to their VoiceOver announcement so screen
        /// readers can distinguish change intent without reading the
        /// `+`/`−` glyph in front of each line.
        var accessibilityPrefix: String {
            switch self {
            case .common: return "Unchanged:"
            case .addedOnRight: return "Added:"
            case .removedFromLeft: return "Removed:"
            }
        }

        /// Single-character marker the diff lenses render in the gutter.
        /// Lifted out of the surfaces so a future glyph swap (e.g.
        /// switching to coloured triangles) lands in one place.
        var markerGlyph: String {
            switch self {
            case .common: return " "
            case .addedOnRight: return "+"
            case .removedFromLeft: return "−"
            }
        }
    }

    struct DiffLine: Equatable {
        let origin: Origin
        let leftLine: Int?    // 1-indexed source line, nil when added on the right
        let rightLine: Int?   // 1-indexed source line, nil when removed
        let text: String
    }

    struct DiffResult: Equatable {
        let lines: [DiffLine]
        var added: Int { lines.filter { $0.origin == .addedOnRight }.count }
        var removed: Int { lines.filter { $0.origin == .removedFromLeft }.count }
        var unchanged: Int { lines.filter { $0.origin == .common }.count }
    }

    /// Compute a line-granularity diff. Newlines are split off without
    /// re-allocating a copy of the entire input string for each line.
    static func diff(left: String, right: String) -> DiffResult {
        let leftLines = splitLines(left)
        let rightLines = splitLines(right)
        return diff(leftLines: leftLines, rightLines: rightLines)
    }

    static func diff(leftLines: [String], rightLines: [String]) -> DiffResult {
        let m = leftLines.count
        let n = rightLines.count

        // LCS length matrix as a flat Int array. Column-major access
        // pattern, but for small m/n the layout doesn't matter.
        var lengths = [Int](repeating: 0, count: (m + 1) * (n + 1))
        @inline(__always) func at(_ i: Int, _ j: Int) -> Int { lengths[i * (n + 1) + j] }
        @inline(__always) func set(_ i: Int, _ j: Int, _ v: Int) { lengths[i * (n + 1) + j] = v }

        for i in 0..<m {
            for j in 0..<n {
                if leftLines[i] == rightLines[j] {
                    set(i + 1, j + 1, at(i, j) + 1)
                } else {
                    set(i + 1, j + 1, max(at(i + 1, j), at(i, j + 1)))
                }
            }
        }

        // Backtrace.
        var out: [DiffLine] = []
        out.reserveCapacity(m + n)
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && leftLines[i - 1] == rightLines[j - 1] {
                out.append(DiffLine(origin: .common, leftLine: i, rightLine: j, text: leftLines[i - 1]))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || at(i, j - 1) >= at(i - 1, j)) {
                out.append(DiffLine(origin: .addedOnRight, leftLine: nil, rightLine: j, text: rightLines[j - 1]))
                j -= 1
            } else if i > 0 {
                out.append(DiffLine(origin: .removedFromLeft, leftLine: i, rightLine: nil, text: leftLines[i - 1]))
                i -= 1
            }
        }
        out.reverse()
        return DiffResult(lines: out)
    }

    /// Split on `\n` only; trailing empty line is suppressed (matches
    /// `git diff` behaviour and keeps the diff visually clean for
    /// notes that end on a final newline).
    static func splitLines(_ s: String) -> [String] {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
