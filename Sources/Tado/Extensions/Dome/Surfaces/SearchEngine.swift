import Foundation

/// Pure-Swift ranker the Dome Search surface uses to score note
/// summaries against a free-text query.
///
/// This sits in front of the Rust embedding-based search (which
/// requires a live Dome daemon) so the Search front door has a
/// reasonable answer even when the daemon is offline, fixture vaults
/// are tiny, or no embedding model is loaded yet. A future sprint
/// will swap the ranker for `tado_dome_search` FFI when bt-core
/// exposes one — the surface's `DomeRpcClient.search` boundary
/// stays stable across that swap.
///
/// Scoring is a small bag of heuristics chosen to make the P1
/// acceptance harness — top-3 ≥ 0.85 on a fixed query→expected-doc-id
/// table — pass on a 200-doc fixture without any embedding model:
///
///   - exact match on title  → +5.0
///   - title prefix match    → +3.0
///   - title contains query  → +2.0
///   - per-token coverage    → +1.0 each (tokens within title)
///   - per-token coverage    → +0.4 each (tokens within topic)
///   - per-token coverage    → +0.2 each (tokens within slug)
///   - recency bonus         → up to +0.5 by `sortTimestamp`
///
/// All matching is case-insensitive and diacritic-insensitive.
enum SearchEngine {
    struct Scored: Equatable {
        let note: DomeRpcClient.NoteSummary
        let score: Double
    }

    /// Rank `notes` by relevance to `query`. Returns at most `limit`
    /// hits, descending by score, ties broken by `sortTimestamp` so
    /// fresher notes win.
    static func rank(
        query rawQuery: String,
        notes: [DomeRpcClient.NoteSummary],
        limit: Int = 50
    ) -> [Scored] {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }

        let now = Date()
        let mostRecent = notes.compactMap { $0.updatedAt ?? $0.createdAt }.max() ?? now
        let oldestSpan = max(1.0, now.timeIntervalSince(mostRecent.addingTimeInterval(-86_400 * 30)))

        var scored: [Scored] = []
        scored.reserveCapacity(notes.count)
        for note in notes {
            let title = normalize(note.title)
            let topic = normalize(note.topic)
            let slug = normalize(note.slug)

            var score = 0.0
            if !title.isEmpty {
                if title == query { score += 5.0 }
                else if title.hasPrefix(query) { score += 3.0 }
                else if title.contains(query) { score += 2.0 }
            }
            for token in tokens {
                if title.contains(token) { score += 1.0 }
                if topic.contains(token) { score += 0.4 }
                if slug.contains(token) { score += 0.2 }
            }

            if score > 0, let ts = note.updatedAt ?? note.createdAt {
                let age = now.timeIntervalSince(ts)
                let bonus = max(0.0, 0.5 * (1.0 - age / oldestSpan))
                score += bonus
            }

            if score > 0 {
                scored.append(Scored(note: note, score: score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.note.sortTimestamp > rhs.note.sortTimestamp
        }
        if scored.count > limit { scored.removeLast(scored.count - limit) }
        return scored
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
