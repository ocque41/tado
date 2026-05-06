import Foundation
import SwiftUI

/// Live state of the Tado Use drawer chat. One conversation at a
/// time. Held by `TadoApp` as a @State singleton, injected via
/// `.environment(...)` into the main window so views can read +
/// the `TadoUseEngine` can mutate.
///
/// In-memory only for v1 — closing the app loses the conversation.
/// Persistence lands in v1.5 once the turn shape stabilizes.
///
/// ## Streaming scratchpad split
///
/// To avoid SwiftUI re-rendering every turn row on every text-delta
/// event (~50 Hz during streaming), the active assistant turn lives
/// in DEDICATED scalars (`streamingText`, `streamingToolCalls`, …),
/// NOT in the `turns` array. The panel renders finalized turns from
/// `turns` via `ForEach` and the live turn from a separate view
/// bound to the scratchpad properties. Only the live row
/// re-evaluates per token; the array stays stable across the
/// entire streaming window. When the engine sees the run finish,
/// `finalizeStreamingTurn()` copies the scratchpad into a `Turn`
/// and appends to `turns` (one mutation per turn), then clears.
///
/// Without this split, mutating `turns[i].text` per delta
/// invalidated the `turns` array's keypath and rebuilt every
/// `TadoUseTurnRow`. With ~10 visible turns and 50 Hz cadence
/// that's ~200 row rebuilds/sec on the main thread.
@Observable
@MainActor
final class TadoUseState {
    /// One conversation. The drawer scrolls a single ordered list
    /// of these.
    var conversationID: UUID = UUID()

    /// Engine selected by the picker in the drawer header. Defaults
    /// to Claude — Codex is exposed in the picker for forward
    /// compatibility but `codex exec` doesn't yet accept
    /// `--mcp-config`, so selecting Codex returns an explanatory
    /// turn instead of spawning. Switching engines mid-conversation
    /// starts a fresh `conversationID` so resumes don't get crossed.
    var engine: TerminalEngine = .claude

    /// Finalized turns only. Mutated at turn boundaries (~1× per
    /// human-agent exchange), NOT per text-delta. The active
    /// assistant turn lives in the scratchpad below until it
    /// finalizes.
    var turns: [Turn] = []

    /// True while a subprocess is actively streaming. The drawer
    /// disables the input field and shows a Stop button while this
    /// is set. Cleared when the subprocess exits or the user clicks
    /// Stop.
    var isStreaming: Bool = false

    /// Latest error string from the engine, if any. Surfaced as a
    /// destructive-tinted footer chip in the drawer until the next
    /// turn starts.
    var lastError: String? = nil

    /// Approximate token usage (input + output, summed across all
    /// `result` events seen). Reset on `clearConversation()`.
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    // MARK: - Streaming scratchpad
    //
    // The active assistant turn lives here while it streams. Bound
    // to a dedicated SwiftUI view so per-token text mutations
    // invalidate ONLY that view, not the parent ForEach.

    /// Stable id for the active streaming turn so the rendering
    /// view can use it for animation / scroll anchoring. nil when
    /// no turn is streaming.
    var streamingTurnID: UUID? = nil

    /// Engine that produced the active streaming turn. Recorded so
    /// the live row's badge stays correct even if the user flips
    /// the engine picker mid-stream (rare; we still finalize the
    /// in-flight turn under its original engine).
    var streamingEngine: TerminalEngine = .claude

    /// Accumulating assistant text for the active streaming turn.
    /// Per-token mutations land here.
    var streamingText: String = ""

    /// Tool calls observed in the active streaming turn. Mutated
    /// when the engine sees `content_block_start`/`tool_result`.
    var streamingToolCalls: [Turn.ToolCall] = []

    /// Wall-clock time the streaming turn started. Same shape as
    /// `Turn.startedAt`; rolled into the finalized Turn at
    /// finalize time.
    var streamingStartedAt: Date? = nil

    // MARK: - Streaming lifecycle

    /// Call before `engine.spawn(...)`. Initializes the scratchpad
    /// for a fresh assistant turn.
    func beginStreamingTurn(engine: TerminalEngine) {
        streamingTurnID = UUID()
        streamingEngine = engine
        streamingText = ""
        streamingToolCalls = []
        streamingStartedAt = Date()
    }

    /// Call when the engine sees the `result` event or the
    /// subprocess terminates. Promotes the scratchpad into a
    /// finalized Turn appended to `turns`, then clears the
    /// scratchpad. Idempotent — calling without an active
    /// streaming turn is a no-op.
    func finalizeStreamingTurn() {
        guard let id = streamingTurnID,
              let started = streamingStartedAt else {
            return
        }
        let finalTurn = Turn(
            id: id,
            role: .assistant,
            text: streamingText,
            toolCalls: streamingToolCalls,
            startedAt: started,
            finishedAt: Date(),
            engine: streamingEngine
        )
        turns.append(finalTurn)
        streamingTurnID = nil
        streamingText = ""
        streamingToolCalls = []
        streamingStartedAt = nil
    }

    /// True when the live row should be visible (we have a
    /// streaming turn even if `isStreaming` already flipped to
    /// false at process exit but before finalize ran).
    var hasStreamingTurn: Bool { streamingTurnID != nil }

    /// Reset everything. Called by the "+ New conversation" button.
    /// Generates a fresh `conversationID` — Claude's `--session-id`
    /// will route the next turn into a brand-new server-side
    /// conversation rather than resuming the prior one.
    func clearConversation() {
        conversationID = UUID()
        turns.removeAll()
        isStreaming = false
        lastError = nil
        inputTokens = 0
        outputTokens = 0
        streamingTurnID = nil
        streamingText = ""
        streamingToolCalls = []
        streamingStartedAt = nil
    }

    // MARK: - Turn types

    enum Role: String, Codable {
        case user
        case assistant
    }

    /// One bubble in the chat. `assistant` turns are written in
    /// one shot when finalized from the streaming scratchpad.
    /// `user` turns are written in one shot at submit time.
    struct Turn: Identifiable, Equatable {
        let id: UUID
        var role: Role
        var text: String
        var toolCalls: [ToolCall]
        var startedAt: Date
        var finishedAt: Date?
        /// Engine that produced this turn. Recorded so a
        /// conversation that switched engines mid-stream still
        /// renders the right badge per turn.
        var engine: TerminalEngine

        init(
            id: UUID = UUID(),
            role: Role,
            text: String = "",
            toolCalls: [ToolCall] = [],
            startedAt: Date = Date(),
            finishedAt: Date? = nil,
            engine: TerminalEngine
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.toolCalls = toolCalls
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.engine = engine
        }

        /// One tool invocation by the assistant. Status flips from
        /// `pending` → `complete` once the model posts the matching
        /// `tool_result`.
        struct ToolCall: Identifiable, Equatable {
            let id: String
            var name: String
            var input: String
            var output: String?
            var status: Status

            enum Status: String, Equatable {
                case pending
                case complete
                case failed
            }
        }
    }

    /// Back-compat shim: existing call sites that referenced
    /// `TadoUseState.ToolCall` keep working. Newly-namespaced as
    /// `Turn.ToolCall` to match where it conceptually belongs.
    typealias ToolCall = Turn.ToolCall
}
