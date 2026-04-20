import Foundation

/// Maintains `<project>/.tado/.gitignore` according to the project's
/// declared `commitPolicy` (see `ProjectSettings.CommitPolicy`). Called
/// from `ScopedConfig.writeProjectShared` whenever `config.json` is
/// written; also safe to call directly from migrations.
///
/// The file is fully owned by Tado when policy is `shared` or
/// `localOnly` — it is rewritten verbatim on each call. Users who want
/// to hand-maintain the file should set policy to `none`, at which
/// point Tado leaves it alone.
enum ProjectGitignore {
    static func apply(policy: ProjectSettings.CommitPolicy, projectRoot: URL) {
        let url = StorePaths.projectTadoDir(projectRoot: projectRoot)
            .appendingPathComponent(".gitignore")

        switch policy {
        case .shared:
            write(contents: sharedBody, to: url)
        case .localOnly:
            write(contents: localOnlyBody, to: url)
        case .none:
            // Leave whatever is there. If the file doesn't exist, don't
            // create it — the user opted out of Tado managing it.
            return
        }
    }

    // MARK: - Templates

    /// Default policy. `config.json` is tracked; `local.json` and all
    /// runtime/log artefacts are ignored.
    private static let sharedBody: String = """
    # Managed by Tado — edit via Settings → Project → Commit policy,
    # or set policy to `none` in `config.json` to hand-maintain.
    local.json
    hooks.log
    eternal/runs/
    dispatch/runs/
    memory/notes/archive.tar.gz
    """

    /// Nothing Tado-specific ends up in git. `config.json` itself is
    /// ignored, so teammates don't inherit settings from this machine.
    private static let localOnlyBody: String = """
    # Managed by Tado — `local-only` policy.
    # config.json is ignored here so Tado settings do not leak to git.
    # Flip back to `shared` in Settings to commit `config.json`.
    config.json
    local.json
    hooks.log
    eternal/runs/
    dispatch/runs/
    memory/notes/archive.tar.gz
    """

    // MARK: - Private

    private static func write(contents: String, to url: URL) {
        do {
            try AtomicStore.write(
                (contents + "\n").data(using: .utf8) ?? Data(),
                to: url
            )
        } catch {
            NSLog("[ProjectGitignore] write failed at \(url.path): \(error)")
        }
    }
}
