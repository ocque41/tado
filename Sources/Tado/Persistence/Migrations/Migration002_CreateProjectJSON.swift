import Foundation
import SwiftData

/// Migration 002: for every existing `Project` row, ensure its
/// `<rootPath>/.tado/config.json` exists (seeded from SwiftData
/// fields) and `.tado/.gitignore` reflects the default `shared`
/// commit policy.
///
/// This is the per-project equivalent of Migration001. After this
/// migration, `config.json` is the source of truth for the fields it
/// covers; `Project` SwiftData fields stay in sync via
/// `ProjectSettingsSync`.
///
/// Idempotent: skips any project whose `config.json` already exists
/// (the runtime sync already seeded it, or a previous migration run
/// did). Safe to re-apply.
struct Migration002_CreateProjectJSON: Migration {
    let id = 2
    let name = "create per-project config.json + .gitignore from SwiftData Project rows"

    func apply(context: ModelContext) throws {
        let descriptor = FetchDescriptor<Project>()
        let rows = (try? context.fetch(descriptor)) ?? []

        for row in rows {
            let rootURL = URL(fileURLWithPath: row.rootPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()

            let configPath = StorePaths.projectConfigFile(projectRoot: rootURL)
            // Only seed if the file doesn't already exist — preserves
            // any hand-edited / earlier-written config.
            if FileManager.default.fileExists(atPath: configPath.path) { continue }

            var settings = ProjectSettings()
            settings.writer = "migration-002"
            settings.updatedAt = Date()
            settings.project.name = row.name
            settings.eternal.mode = row.eternalMode
            settings.eternal.loopKind = row.eternalLoopKind
            settings.eternal.completionMarker = row.eternalCompletionMarker
            settings.eternal.sprintEval = row.eternalSprintEval
            settings.eternal.sprintImprove = row.eternalSprintImprove
            settings.eternal.skipPermissions = row.eternalSkipPermissions

            try AtomicStore.encode(settings, to: configPath)
            ProjectGitignore.apply(policy: settings.commitPolicy, projectRoot: rootURL)
            Self.writeTeammateReadme(projectRoot: rootURL)
        }
    }

    /// Drop a one-shot README beside `config.json` so a teammate who
    /// clones the repo sees what `.tado/` is before they think about
    /// deleting it. Only written if missing — never overwrites a
    /// hand-edited copy.
    static func writeTeammateReadme(projectRoot: URL) {
        let readme = StorePaths.projectTadoDir(projectRoot: projectRoot)
            .appendingPathComponent("README.md")
        if FileManager.default.fileExists(atPath: readme.path) { return }

        let body = """
        # .tado/

        This directory holds per-project state for **Tado**, a macOS terminal
        multiplexer for AI coding agents (https://tado.app).

        ## What's in here

        | File / folder       | Committed? | Purpose                                                            |
        |---------------------|------------|--------------------------------------------------------------------|
        | `config.json`       | yes        | Project-shared settings — engine, eternal mode, sprint prompts.    |
        | `local.json`        | no         | Per-machine overrides. Gitignored by default.                      |
        | `memory/project.md` | yes        | Long-lived context agents auto-inject on spawn.                    |
        | `memory/notes/`     | yes        | Timestamped agent notes. Searchable via `tado-memory search`.      |
        | `eternal/runs/`     | no         | Per-run state for Eternal (long-running agent loops).              |
        | `dispatch/runs/`    | no         | Per-run state for Dispatch (multi-phase architect plans).          |
        | `hooks/`            | yes        | Bash hooks shared with the team.                                   |
        | `.gitignore`        | yes        | Auto-maintained by Tado based on `config.json → commitPolicy`.     |

        ## Changing what's committed

        `config.json` has a top-level `"commitPolicy"` field:

        - `"shared"` (default) — `config.json` is tracked; `local.json` is gitignored.
        - `"local-only"` — both files gitignored; nothing Tado-specific leaks to git.
        - `"none"` — Tado stops managing `.gitignore`; you maintain it yourself.

        Set via the Settings UI, or from the terminal:

        ```bash
        tado-config set project commitPolicy '"local-only"'
        ```

        ## Safe to delete?

        Yes — Tado rebuilds it from SwiftData state on next launch. But teammates
        will lose anything you had committed (prompts, memory, hooks).
        """

        try? AtomicStore.write(
            (body + "\n").data(using: .utf8) ?? Data(),
            to: readme
        )
    }
}
