import Foundation

/// A7 — Register the Rust `tado-mcp` binary with Claude Code at app
/// launch, mirroring the pattern `DomeExtension.onAppLaunch` uses
/// for the `dome-mcp` bridge. Silent success path on every launch:
/// if `claude` isn't on PATH, or registration already lists a
/// `tado` server, this is a no-op.
///
/// Why not wired through `AppExtension.onAppLaunch`
/// -----------------------------------------------
/// tado-mcp isn't a Tado extension in the ExtensionRegistry sense —
/// there's no window, no `makeView`, no per-project state. It's a
/// stdio bridge that Claude Code spawns on demand. Keeping the
/// registration code in a plain service file rather than a phantom
/// extension preserves the compile-time registry's invariant that
/// every entry has a surface the user can open.
///
/// Resolution order for the binary
/// -------------------------------
/// 1. `Tado.app/Contents/MacOS/tado-mcp` when running bundled.
/// 2. `tado-core/target/release/tado-mcp` when running `swift run`
///    from the repo (dev).
/// 3. Give up — print a line and move on; manual `claude mcp add`
///    remains available for users with non-standard installs.
enum TadoMcpAutoRegister {
    /// Kick off auto-registration on a detached task. Returns
    /// immediately so app-launch is never blocked by shelling out
    /// to `claude`.
    static func kickoff() {
        Task.detached(priority: .utility) {
            await register()
        }
    }

    private static func register() async {
        guard isClaudeCliAvailable() else { return }
        if isTadoAlreadyRegistered() { return }
        let binary = resolveBinaryPath()
        guard FileManager.default.fileExists(atPath: binary) else {
            NSLog("tado-mcp: binary not found at \(binary); skipping auto-register")
            return
        }
        _ = runClaudeMcpAdd(binaryPath: binary)
    }

    private static func isClaudeCliAvailable() -> Bool {
        let (status, _) = runShell("claude --version", timeoutSeconds: 2)
        return status == 0
    }

    /// Matches anything that looks like a `tado` MCP entry in the
    /// output of `claude mcp list`. Node `tado-mcp` shipped under
    /// the name `tado`; re-registering with the same name is fine
    /// as long as we catch this first to avoid a noisy duplicate
    /// warning on every launch.
    private static func isTadoAlreadyRegistered() -> Bool {
        let (status, output) = runShell("claude mcp list 2>/dev/null", timeoutSeconds: 5)
        guard status == 0 else { return false }
        // Match `^\s*tado[:\s]` — the server name is `tado` in both
        // Node and Rust packages.
        if output.range(of: #"(?m)^\s*tado\s*[:\s]"#, options: .regularExpression) != nil {
            return true
        }
        return output.contains(" tado ") || output.contains(" tado:")
    }

    private static func runClaudeMcpAdd(binaryPath: String) -> Bool {
        let q = { (s: String) -> String in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // `claude mcp remove tado --scope user` first so we overwrite
        // any stale Node registration without error. `|| true` so a
        // "not found" doesn't block the add step.
        let cmd = "(claude mcp remove tado --scope user 2>/dev/null || true) && " +
                  "claude mcp add tado --scope user -- \(q(binaryPath)) 2>&1"
        let (status, _) = runShell(cmd, timeoutSeconds: 10)
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

    private static func resolveBinaryPath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tado-mcp")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let devBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tado-core/target/release/tado-mcp")
        return devBuild.path
    }
}
