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
    var templates: [LibraryEntry] = []
    var snippets: [LibraryEntry] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        writer = try c.decodeIfPresent(String.self, forKey: .writer) ?? "tado-app"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        ui = try c.decodeIfPresent(UI.self, forKey: .ui) ?? UI()
        engine = try c.decodeIfPresent(EngineBlock.self, forKey: .engine) ?? EngineBlock()
        canvas = try c.decodeIfPresent(Canvas.self, forKey: .canvas) ?? Canvas()
        notifications = try c.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        dome = try c.decodeIfPresent(Dome.self, forKey: .dome) ?? Dome()
        templates = try c.decodeIfPresent([LibraryEntry].self, forKey: .templates) ?? []
        snippets = try c.decodeIfPresent([LibraryEntry].self, forKey: .snippets) ?? []
    }

    /// Composer library entry. One struct backs both Templates (full
    /// prompt presets that REPLACE the editor buffer) and Snippets
    /// (short fragments INSERTED at the caret) — the kind is implied
    /// by which array the entry lives in. `body` is plain text in v1;
    /// no placeholder substitution.
    struct LibraryEntry: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var name: String = ""
        var body: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
    }

    struct UI: Codable, Equatable {
        var defaultThemeId: String = "ember"
        var randomTileColor: Bool = false
        var terminalFontSize: Int = 13
        var terminalFontFamily: String = ""
        var cursorBlink: Bool = true
        var bellMode: String = "audible"

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultThemeId = try c.decodeIfPresent(String.self, forKey: .defaultThemeId) ?? "ember"
            randomTileColor = try c.decodeIfPresent(Bool.self, forKey: .randomTileColor) ?? false
            terminalFontSize = try c.decodeIfPresent(Int.self, forKey: .terminalFontSize) ?? 13
            terminalFontFamily = try c.decodeIfPresent(String.self, forKey: .terminalFontFamily) ?? ""
            cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? true
            bellMode = try c.decodeIfPresent(String.self, forKey: .bellMode) ?? "audible"
        }
    }

    struct EngineBlock: Codable, Equatable {
        var `default`: String = "claude"
        var claude: ClaudeSettings = ClaudeSettings()
        var codex: CodexSettings = CodexSettings()
        var advisor: AdvisorSettings = AdvisorSettings()

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            `default` = try c.decodeIfPresent(String.self, forKey: .default) ?? "claude"
            claude = try c.decodeIfPresent(ClaudeSettings.self, forKey: .claude) ?? ClaudeSettings()
            codex = try c.decodeIfPresent(CodexSettings.self, forKey: .codex) ?? CodexSettings()
            advisor = try c.decodeIfPresent(AdvisorSettings.self, forKey: .advisor) ?? AdvisorSettings()
        }
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

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "askPermissions"
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "auto"
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "claude-opus-4-7"
            noFlicker = try c.decodeIfPresent(Bool.self, forKey: .noFlicker) ?? false
            mouseEnabled = try c.decodeIfPresent(Bool.self, forKey: .mouseEnabled) ?? true
            scrollSpeed = try c.decodeIfPresent(Int.self, forKey: .scrollSpeed) ?? 3
        }
    }

    struct CodexSettings: Codable, Equatable {
        var mode: String = "defaultPermissions"
        // Same rationale as `ClaudeSettings.effort`: `auto` omits the
        // `-c model_reasoning_effort=` flag and Codex picks its default.
        var effort: String = "auto"
        var model: String = "gpt-5.5"
        var alternateScreen: Bool = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "defaultPermissions"
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "auto"
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5.5"
            alternateScreen = try c.decodeIfPresent(Bool.self, forKey: .alternateScreen) ?? false
        }
    }

    struct AdvisorSettings: Codable, Equatable {
        var enabled: Bool = false
        var defaultsInitialized: Bool = false
        var executioner: AdvisorRoleSettings = AdvisorRoleSettings(
            engine: "claude",
            claude: AdvisorClaudeSettings(
                mode: "askPermissions",
                effort: "auto",
                model: "claude-sonnet-4-6"
            ),
            codex: AdvisorCodexSettings(
                mode: "defaultPermissions",
                effort: "auto",
                model: "gpt-5.4"
            )
        )
        var advisor: AdvisorRoleSettings = AdvisorRoleSettings(
            engine: "claude",
            claude: AdvisorClaudeSettings(
                mode: "askPermissions",
                effort: "high",
                model: "claude-opus-4-7"
            ),
            codex: AdvisorCodexSettings(
                mode: "defaultPermissions",
                effort: "high",
                model: "gpt-5.5"
            )
        )

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            defaultsInitialized = try c.decodeIfPresent(Bool.self, forKey: .defaultsInitialized) ?? false
            executioner = try c.decodeIfPresent(AdvisorRoleSettings.self, forKey: .executioner)
                ?? AdvisorSettings().executioner
            advisor = try c.decodeIfPresent(AdvisorRoleSettings.self, forKey: .advisor)
                ?? AdvisorSettings().advisor
        }
    }

    struct AdvisorRoleSettings: Codable, Equatable {
        var engine: String = "claude"
        var claude: AdvisorClaudeSettings = AdvisorClaudeSettings()
        var codex: AdvisorCodexSettings = AdvisorCodexSettings()

        init(
            engine: String = "claude",
            claude: AdvisorClaudeSettings = AdvisorClaudeSettings(),
            codex: AdvisorCodexSettings = AdvisorCodexSettings()
        ) {
            self.engine = engine
            self.claude = claude
            self.codex = codex
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "claude"
            claude = try c.decodeIfPresent(AdvisorClaudeSettings.self, forKey: .claude) ?? AdvisorClaudeSettings()
            codex = try c.decodeIfPresent(AdvisorCodexSettings.self, forKey: .codex) ?? AdvisorCodexSettings()
        }
    }

    struct AdvisorClaudeSettings: Codable, Equatable {
        var mode: String = "askPermissions"
        var effort: String = "auto"
        var model: String = "claude-sonnet-4-6"

        init(
            mode: String = "askPermissions",
            effort: String = "auto",
            model: String = "claude-sonnet-4-6"
        ) {
            self.mode = mode
            self.effort = effort
            self.model = model
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "askPermissions"
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "auto"
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "claude-sonnet-4-6"
        }
    }

    struct AdvisorCodexSettings: Codable, Equatable {
        var mode: String = "defaultPermissions"
        var effort: String = "auto"
        var model: String = "gpt-5.4"

        init(
            mode: String = "defaultPermissions",
            effort: String = "auto",
            model: String = "gpt-5.4"
        ) {
            self.mode = mode
            self.effort = effort
            self.model = model
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "defaultPermissions"
            effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "auto"
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5.4"
        }
    }

    struct Canvas: Codable, Equatable {
        var gridColumns: Int = 3

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gridColumns = try c.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 3
        }
    }

    struct Notifications: Codable, Equatable {
        var channels: Channels = Channels()
        var eventRouting: [String: [String]] = defaultEventRouting
        var retentionDays: Int = 30
        var quietHours: QuietHours = QuietHours()

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            channels = try c.decodeIfPresent(Channels.self, forKey: .channels) ?? Channels()
            eventRouting = try c.decodeIfPresent([String: [String]].self, forKey: .eventRouting)
                ?? GlobalSettings.defaultEventRouting
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
            quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        }
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

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultKnowledgeScope = try c.decodeIfPresent(String.self, forKey: .defaultKnowledgeScope) ?? "global"
            includeGlobalInProject = try c.decodeIfPresent(Bool.self, forKey: .includeGlobalInProject) ?? true
            defaultKnowledgeKind = try c.decodeIfPresent(String.self, forKey: .defaultKnowledgeKind) ?? "knowledge"
            agentRegistrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentRegistrationEnabled) ?? true
            contextPacksV2 = try c.decodeIfPresent(Bool.self, forKey: .contextPacksV2) ?? false
        }
    }

    struct Channels: Codable, Equatable {
        var inApp: Bool = true
        var system: Bool = true
        var sound: Bool = true
        var dockBadge: Bool = true

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inApp = try c.decodeIfPresent(Bool.self, forKey: .inApp) ?? true
            system = try c.decodeIfPresent(Bool.self, forKey: .system) ?? true
            sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
            dockBadge = try c.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? true
        }
    }

    struct QuietHours: Codable, Equatable {
        var enabled: Bool = false
        var from: String = "22:00"
        var to: String = "08:00"

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            from = try c.decodeIfPresent(String.self, forKey: .from) ?? "22:00"
            to = try c.decodeIfPresent(String.self, forKey: .to) ?? "08:00"
        }
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
