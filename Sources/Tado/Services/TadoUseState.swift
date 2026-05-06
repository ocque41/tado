import Foundation
import SwiftUI

/// Live state of the Tado Use drawer chat. One conversation at a
/// time. Held by `TadoApp` as a @State singleton, injected via
/// `.environment(...)` into the main window so views can read +
/// the `TadoUseEngine` can mutate.
///
/// In-memory only for v1 — closing the app loses the conversation.
/// Persistence lands in v1.5 once the turn shape stabilizes.
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

    /// All turns in the active conversation, oldest first.
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
    }

    // MARK: - Turn types

    enum Role: String, Codable {
        case user
        case assistant
    }

    /// One bubble in the chat. `assistant` turns build incrementally
    /// as stream-json events arrive — `text` accumulates, `toolCalls`
    /// gets one entry per `tool_use` block. `user` turns are written
    /// in one shot at submit time.
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
    }

    /// One tool invocation by the assistant. The drawer shows these
    /// as collapsible disclosure rows under their parent turn.
    /// Status flips from `pending` → `complete` once the model
    /// posts the matching `tool_result`. We don't surface the raw
    /// result body in the bubble — too noisy — but it's stored so
    /// the disclosure can show it on demand.
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
