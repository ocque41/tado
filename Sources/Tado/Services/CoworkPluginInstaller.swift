import Foundation

/// Installs / uninstalls / queries the bundled `tado-cowork-plugin`
/// against the user's Claude install. The plugin lives in the bundled
/// `Tado.app/Contents/Resources/tado-cowork-plugin/` (or, in dev,
/// `tado-core/crates/tado-cowork-plugin/`) and is registered as a
/// local marketplace + installed via `claude plugin install`.
///
/// Mirrors the shape of `TadoMcpAutoRegister` and `DomeExtension`'s
/// `claude mcp add dome` flow — shells out to the `claude` CLI and
/// lets it own the file writes into `~/.claude/plugins/cache/` and
/// `~/.claude/settings.json`. We never edit those files directly,
/// which keeps the plugin install behavior identical to what the
/// user would get from running the `claude plugin marketplace add`
/// + `claude plugin install` commands by hand.
///
/// The plugin's MCP servers expose Tado's full 71-tool surface
/// (16 `tado_*` + 18 `dome_*` + 41 `tado_use_*`) to any Claude
/// session — Code or Cowork — that loads the plugin. The plugin
/// also ships a teaching skill (`cowork-tado-tools`) and an agent
/// persona (`cowork-canvas-coworker`).
enum CoworkPluginInstaller {
    /// Plugin name (matches `.claude-plugin/plugin.json`'s `name`).
    static let pluginName = "tado-cowork-plugin"
    /// Local marketplace name. Anthropic's plugin model uses
    /// `<plugin>@<marketplace>` for disambiguation; Tado registers
    /// its bundled tree as a marketplace called `tado-local`.
    static let marketplaceName = "tado-local"

    /// Returns `true` iff the plugin is currently registered in the
    /// user's `~/.claude/settings.json` `enabledPlugins`. Read-only;
    /// safe to call from MainActor (returns immediately on cache
    /// miss). Does not boot any subprocesses — uses a direct file
    /// read because the `claude plugin list` CLI output isn't
    /// stable across versions and shelling out for every Settings
    /// render would be wasteful.
    static func isInstalled() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["enabledPlugins"] as? [String: Any] else {
            return false
        }
        // Plugin entries land as `"<plugin>@<marketplace>": true`.
        // Match the qualified form, since the user could plausibly
        // install the same plugin from multiple marketplaces.
        let qualified = "\(pluginName)@\(marketplaceName)"
        return enabled[qualified] != nil || enabled[pluginName] != nil
    }

    /// Resolve the bundled plugin tree's filesystem path. Tries the
    /// `.app` bundle first (production), then the dev workspace path
    /// (so `swift run Tado` from the repo root works). Returns nil
    /// if neither exists — the caller should surface this to the
    /// user rather than installing a phantom plugin.
    static func resolvePluginRoot() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/tado-cowork-plugin")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let devTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tado-core/crates/tado-cowork-plugin")
        if FileManager.default.fileExists(atPath: devTree.path) {
            return devTree
        }
        return nil
    }

    /// Run the install dance: `claude plugin marketplace add <path>`
    /// then `claude plugin install <plugin>@<marketplace>`. Both
    /// commands are idempotent — the first re-points the marketplace
    /// at the bundled tree (so an upgraded Tado.app picks up the
    /// new plugin tree on next install), and the second is a no-op
    /// if the plugin is already enabled.
    ///
    /// Run on a detached task; never blocks MainActor. On failure,
    /// logs to `os_log` and surfaces the error via NSAlert in the
    /// caller (Settings view watches `lastInstallError`).
    static func install() {
        guard let pluginRoot = resolvePluginRoot() else {
            NSLog("CoworkPluginInstaller.install: plugin tree not found at bundled or dev path")
            return
        }
        guard isClaudeCliAvailable() else {
            NSLog("CoworkPluginInstaller.install: `claude` CLI not on PATH; skipping")
            return
        }
        let q = { (s: String) -> String in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // `marketplace add` is idempotent; existing entries get
        // re-pointed at the new path. We don't rely on `add` failing
        // — the second command is the load-bearing one.
        let cmd = "(claude plugin marketplace add \(q(pluginRoot.path)) 2>/dev/null || true) && " +
                  "claude plugin install \(q("\(pluginName)@\(marketplaceName)")) 2>&1"
        let (status, output) = runShell(cmd, timeoutSeconds: 30)
        if status != 0 {
            NSLog("CoworkPluginInstaller.install failed: status=\(status), output=\(output)")
        } else {
            NSLog("CoworkPluginInstaller.install succeeded")
        }
    }

    /// Uninstall the plugin. Leaves the marketplace registered so a
    /// future re-install is one click away; the operator can run
    /// `claude plugin marketplace remove tado-local` by hand if
    /// they want a fully clean slate.
    static func uninstall() {
        guard isClaudeCliAvailable() else {
            NSLog("CoworkPluginInstaller.uninstall: `claude` CLI not on PATH; skipping")
            return
        }
        let q = { (s: String) -> String in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let cmd = "claude plugin uninstall \(q("\(pluginName)@\(marketplaceName)")) 2>&1 || " +
                  "claude plugin uninstall \(q(pluginName)) 2>&1"
        let (status, output) = runShell(cmd, timeoutSeconds: 30)
        if status != 0 {
            NSLog("CoworkPluginInstaller.uninstall failed: status=\(status), output=\(output)")
        } else {
            NSLog("CoworkPluginInstaller.uninstall succeeded")
        }
    }

    private static func isClaudeCliAvailable() -> Bool {
        let (status, _) = runShell("claude --version", timeoutSeconds: 2)
        return status == 0
    }

    private static func runShell(_ command: String, timeoutSeconds: Int) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "")
        }
        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
