import Foundation

/// In-memory / on-disk representation of `global.json`. Canonical
/// source of truth for user-global settings; mirrored into the
/// SwiftData `AppSettings` row as a queryable cache by
/// `AppSettingsSync`.
///
/// The JSON layout is stable and documented in the architecture
/// plan. Every field has a default so partial JSON (or brand-new
/// install) loads cleanly.
struct GlobalSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var writer: String = "tado-app"
    var updatedAt: Date = Date()

    var ui: UI = UI()
    var engine: EngineBlock = EngineBlock()
    var canvas: Canvas = Canvas()
    var notifications: Notifications = Notifications()
    var dome: Dome = Dome()

    struct UI: Codable, Equatable {
        var defaultThemeId: String = "ember"
        var randomTileColor: Bool = false
        var terminalFontSize: Int = 13
        var terminalFontFamily: String = ""
        var cursorBlink: Bool = true
        var bellMode: String = "audible"
    }

    struct EngineBlock: Codable, Equatable {
        var `default`: String = "claude"
        var claude: ClaudeSettings = ClaudeSettings()
        var codex: CodexSettings = CodexSettings()
    }

    struct ClaudeSettings: Codable, Equatable {
        var mode: String = "askPermissions"
        // `auto` means "do not pass --effort"; Claude Code picks the
        // model-appropriate default. See `ClaudeEffort` in AppState.swift
        // for why this is the default — Tado has no source of truth for
        // per-model effort caps and shouldn't pretend otherwise.
        var effort: String = "auto"
        var model: String = "claude-opus-4-7"
        var noFlicker: Bool = false
        var mouseEnabled: Bool = true
        var scrollSpeed: Int = 3
    }

    struct CodexSettings: Codable, Equatable {
        var mode: String = "defaultPermissions"
        // Same rationale as `ClaudeSettings.effort`: `auto` omits the
        // `-c model_reasoning_effort=` flag and Codex picks its default.
        var effort: String = "auto"
        var model: String = "gpt-5.5"
        var alternateScreen: Bool = false
    }

    struct Canvas: Codable, Equatable {
        var gridColumns: Int = 3
    }

    struct Notifications: Codable, Equatable {
        var channels: Channels = Channels()
        var eventRouting: [String: [String]] = defaultEventRouting
        var retentionDays: Int = 30
        var quietHours: QuietHours = QuietHours()
    }

    struct Dome: Codable, Equatable {
        var defaultKnowledgeScope: String = "global"
        var includeGlobalInProject: Bool = true
        var defaultKnowledgeKind: String = "knowledge"
        var agentRegistrationEnabled: Bool = true
        /// Phase 4 (v0.13.0) — dark-launch toggle for the Rust spawn
        /// preamble composer. `false` keeps the v0.10 Swift composer
        /// in the hot path; `true` delegates to bt-core's
        /// `tado_dome_compose_spawn_preamble`. Both produce
        /// byte-identical output for the same input — the flag exists
        /// so we can flip the default per release without touching
        /// agents that have memorised the marker contract.
        var contextPacksV2: Bool = false
    }

    struct Channels: Codable, Equatable {
        var inApp: Bool = true
        var system: Bool = true
        var sound: Bool = true
        var dockBadge: Bool = true
    }

    struct QuietHours: Codable, Equatable {
        var enabled: Bool = false
        var from: String = "22:00"
        var to: String = "08:00"
    }

    static let defaultEventRouting: [String: [String]] = [
        "terminal.bell":            ["sound"],
        "terminal.spawnFailed":     ["inApp", "system"],
        // Routed to dockBadge only — finishing a turn shouldn't pop a
        // banner. The dock badge + per-row idle indicator are enough.
        "terminal.idle":            ["dockBadge"],
        // Loud: inApp + system + sound + dock. The agent is blocked
        // until the user responds, so we want the user to notice.
        "terminal.awaitingResponse":["inApp", "system", "sound", "dockBadge"],
        "terminal.completed":       ["inApp", "system", "dockBadge"],
        "terminal.failed":          ["inApp", "system", "dockBadge"],
        "ipc.messageReceived":      ["inApp", "dockBadge"],
        "eternal.phaseCompleted":   ["inApp", "system"],
        "eternal.runCompleted":     ["inApp", "system", "sound"],
        "eternal.workerWedged":     ["inApp", "system", "sound"],
        "dispatch.phaseCompleted":  ["inApp"],
        "dispatch.runCompleted":    ["inApp", "system", "sound"],
        "user.broadcast":           ["inApp", "system"]
    ]
}
