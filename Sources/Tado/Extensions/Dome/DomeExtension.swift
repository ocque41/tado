import Foundation
import SwiftUI
import CTadoCore

/// Dome — Tado's always-on second-brain service.
///
/// The extension has two responsibilities:
/// - **Background service (primary).** `onAppLaunch()` fires at
///   process start and calls the `tado_dome_start` FFI, which spawns
///   the bt-core RPC daemon on a dedicated Tokio runtime owned by
///   `libtado_core.a`. From then on every Claude Code agent launched
///   inside a Tado terminal can reach the daemon through the
///   `dome-mcp` stdio bridge (Phase 3).
/// - **UI surface (secondary).** The Extensions page renders a card
///   that opens `DomeRootView` in its own window. Phase 2 ships a
///   branded placeholder; Phase 5 fills in the four surfaces (User
///   Notes / Agent Notes / Calendar / Knowledge).
///
/// Vault location
/// --------------
/// `~/Library/Application Support/Tado/dome/` per the Phase-2 storage
/// plan. bt-core's `open_vault` creates the layout (`.bt/`,
/// `topics/inbox/`, etc.) on first launch, so we don't precreate it
/// here — just make sure the parent directory exists.
enum DomeExtension: AppExtension {
    static let manifest = ExtensionManifest(
        id: "dome",
        displayName: "Dome",
        shortDescription: "Second brain for AI agents — vector-searchable notes, calendar of agent activity, knowledge graph.",
        iconSystemName: "brain",
        version: "0.2.0",
        defaultWindowSize: ExtensionManifest.Size(width: 1100, height: 800),
        windowResizable: true
    )

    @MainActor @ViewBuilder
    static func makeView() -> AnyView {
        AnyView(DomeRootView())
    }

    /// Ensures the vault directory exists, then boots the bt-core
    /// daemon. Called once at app launch through
    /// `ExtensionRegistry.runOnAppLaunchHooks()`; the FFI itself
    /// guards against double-start so repeated invocations are safe.
    ///
    /// Publishes `.domeDaemonStarted` on success or `.domeDaemonFailed`
    /// on any non-zero status. The UI surfaces never block on the
    /// daemon — they render an "offline" state if the RPC client
    /// can't reach the socket.
    static func onAppLaunch() async {
        let vaultURL = DomeVault.resolveRoot()
        do {
            try FileManager.default.createDirectory(
                at: vaultURL,
                withIntermediateDirectories: true
            )
        } catch {
            await publishFailure(code: 3, vaultPath: vaultURL.path)
            return
        }

        let status = vaultURL.path.withCString { cstr in
            tado_dome_start(cstr)
        }

        if status == 0 {
            let mcpPath = resolveMcpBinaryPath()
            let statusLinePath = installStatusLineScript(vaultPath: vaultURL.path)
            await MainActor.run {
                EventBus.shared.publish(.domeDaemonStarted(vaultPath: vaultURL.path, mcpBinaryPath: mcpPath))
            }
            if let statusLinePath {
                registerStatusLineIfSafe(scriptPath: statusLinePath)
            }
            await registerMcpIfNeeded(vaultPath: vaultURL.path, mcpBinaryPath: mcpPath)
        } else {
            await publishFailure(code: status, vaultPath: vaultURL.path)
        }
    }

    /// Best-effort MCP auto-registration with Claude Code. Skipped on
    /// any failure — the Notifications extension's daemon-started
    /// event already carries the manual `claude mcp add` command for
    /// users who have Claude Code installed in a non-default path or
    /// want to control the registration themselves.
    ///
    /// Sequence:
    /// 1. `claude mcp list` — bail early if dome is already registered.
    /// 2. `tado_dome_issue_token("dome-extension", "search,read,note,schedule")` —
    ///    mint a fresh token, persisted to `<vault>/.bt/config.toml`.
    /// 3. `claude mcp add dome --scope user -- <mcp-binary> <vault> <token>` —
    ///    wire it up.
    ///
    /// All failure paths publish `.domeMcpRegisterFailed`-equivalent
    /// info via the shared banner; the absence of the dome MCP server
    /// never blocks the daemon itself from running.
    private static func registerMcpIfNeeded(vaultPath: String, mcpBinaryPath: String) async {
        guard isClaudeCliAvailable() else {
            return
        }
        if isDomeAlreadyRegistered() {
            return
        }
        guard let token = issueMcpToken() else {
            return
        }
        _ = runClaudeMcpAdd(vaultPath: vaultPath, mcpBinaryPath: mcpBinaryPath, token: token)
    }

    /// True iff `claude` is resolvable on the spawned shell's PATH.
    /// Runs `claude --version` with a 2-second timeout; any non-zero
    /// exit or timeout means we skip auto-register cleanly.
    private static func isClaudeCliAvailable() -> Bool {
        let (status, _) = runShell("claude --version", timeoutSeconds: 2)
        return status == 0
    }

    /// Greps `claude mcp list` for a line containing "dome". If the
    /// command fails (Claude not signed in, malformed output, etc.)
    /// we assume not-registered and try to add — the `claude mcp add`
    /// call itself is idempotent-enough (it'll error on duplicate,
    /// which we ignore).
    private static func isDomeAlreadyRegistered() -> Bool {
        let (status, output) = runShell("claude mcp list 2>/dev/null", timeoutSeconds: 5)
        guard status == 0 else { return false }
        return output.range(of: #"(?m)^\s*dome\s*[:\s]"#, options: .regularExpression) != nil
            || output.contains("dome ") || output.contains("dome:") || output.contains(" dome")
    }

    /// Mints a fresh token for the dome-mcp registration via the
    /// `tado_dome_issue_token` FFI. Returns nil on any failure
    /// (vault not open, bt-core rejection, null pointer). The token
    /// is persisted to `<vault>/.bt/config.toml` by bt-core;
    /// subsequent launches can mint a new one without conflict (the
    /// config accumulates agent tokens until revoked).
    private static func issueMcpToken() -> String? {
        let caps = "search,read,note,schedule,graph,context,status"
        return "dome-extension".withCString { agentCstr in
            caps.withCString { capsCstr in
                guard let raw = tado_dome_issue_token(agentCstr, capsCstr) else {
                    return Optional<String>.none
                }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
    }

    /// Installs the script that Claude Code's statusLine feature can
    /// run. The Rust FFI returns the script path plus a settings
    /// snippet; Swift only needs the path.
    private static func installStatusLineScript(vaultPath: String) -> String? {
        let json = vaultPath.withCString { vaultC -> String? in
            guard let raw = tado_dome_install_status_line_script(vaultC) else {
                return nil
            }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["script_path"] as? String else {
            return nil
        }
        return path
    }

    /// Claude docs configure status lines through `~/.claude/settings.json`.
    /// We only fill an empty/missing statusLine or refresh one previously
    /// owned by Tado. A user custom status line is left untouched.
    private static func registerStatusLineIfSafe(scriptPath: String) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: settingsURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            }
            if let existing = root["statusLine"] as? [String: Any],
               let command = existing["command"] as? String,
               !command.contains("tado-statusline.py") {
                return
            }
            root["statusLine"] = [
                "type": "command",
                "command": shellEscape(scriptPath),
                "padding": 1,
                "refreshInterval": 5
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `claude mcp add dome --scope user -- <binary> <vault> <token>`.
    /// Returns true on exit code 0. Both silent duplicate-server and
    /// silent success look identical (exit 0), which is fine — we
    /// only gate on "is it registered now?" via the list call on the
    /// next launch.
    private static func runClaudeMcpAdd(vaultPath: String, mcpBinaryPath: String, token: String) -> Bool {
        // Shell-escape aggressively: vault path can contain spaces.
        let q = { (s: String) -> String in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let cmd = "claude mcp add dome --scope user -- \(q(mcpBinaryPath)) \(q(vaultPath)) \(q(token)) 2>&1"
        let (status, _) = runShell(cmd, timeoutSeconds: 10)
        return status == 0
    }

    /// Minimal process runner. Returns (exit-status, combined-output).
    /// Kills the child on timeout. Never throws; errors map to a
    /// nonzero exit.
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

        // Simple timeout via DispatchWorkItem + terminate.
        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Resolves the path to the `dome-mcp` binary. In a bundled app
    /// it sits at `Tado.app/Contents/MacOS/dome-mcp`. In `swift run`
    /// dev sessions it lives at `tado-core/target/release/dome-mcp`.
    /// Shown to the user in the Notifications extension so they can
    /// copy/paste the `claude mcp add` command until Phase 3b wires
    /// full auto-registration.
    private static func resolveMcpBinaryPath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/dome-mcp")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let devBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tado-core/target/release/dome-mcp")
        return devBuild.path
    }

    @MainActor
    private static func publishFailure(code: Int32, vaultPath: String) {
        EventBus.shared.publish(.domeDaemonFailed(code: code, vaultPath: vaultPath))
    }
}

/// Single source of truth for where Dome's vault lives on disk.
/// Keeping it in an enum (not scattered across the extension) means
/// every surface + the FFI entry point resolves the same path.
enum DomeVault {
    /// `<active Tado storage root>/dome/`.
    ///
    /// The active root is normally `~/Library/Application Support/Tado`,
    /// but Settings → Storage can move it. Dome follows the same root as
    /// settings, memory, events, cache, and backups.
    static func resolveRoot() -> URL {
        StorePaths.root.appendingPathComponent("dome", isDirectory: true)
    }
}
