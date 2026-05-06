import Foundation

/// Register `tado-use-bridge` with Claude Code (and Codex, on the
/// engines that read the same `~/.claude.json` shape) at app
/// launch. Mirrors `TadoMcpAutoRegister`'s semantics — one detached
/// task at boot; no-op if the binary isn't bundled or the `claude`
/// CLI isn't on PATH; idempotent if the registrar's last write
/// already lives in `~/.claude.json`.
///
/// Why a separate file (vs. extending `TadoMcpAutoRegister`):
/// keeps the `tado` MCP entry's lookup logic small and focused.
/// The bridge has its own dev-build resolution path (Swift
/// `.build/{release,debug}` instead of Cargo's `tado-core/target/
/// release`), so a single function would have to fork on the name
/// anyway.
enum TadoUseBridgeAutoRegister {
    static func kickoff() {
        Task.detached(priority: .utility) {
            await register()
        }
    }

    private static func register() async {
        guard isClaudeCliAvailable() else { return }
        let binary = resolveBinaryPath()
        guard FileManager.default.fileExists(atPath: binary) else {
            NSLog("tado-use-bridge: binary not found at \(binary); skipping auto-register")
            return
        }
        if isRegisteredAtPath(binary) { return }
        _ = runClaudeMcpAdd(binaryPath: binary)
    }

    private static func isClaudeCliAvailable() -> Bool {
        let (status, _) = runShell("claude --version", timeoutSeconds: 2)
        return status == 0
    }

    /// True iff `~/.claude.json`'s `mcpServers["tado-use-bridge"]`
    /// entry already points at `binaryPath`. Anything else (missing
    /// entry, stale path) → false → re-register.
    private static func isRegisteredAtPath(_ binaryPath: String) -> Bool {
        let claudeJsonURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: claudeJsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any],
              let entry = mcpServers["tado-use-bridge"] as? [String: Any],
              let command = entry["command"] as? String else {
            return false
        }
        let args = (entry["args"] as? [String]) ?? []
        return command == binaryPath && args.isEmpty
    }

    private static func runClaudeMcpAdd(binaryPath: String) -> Bool {
        let q = { (s: String) -> String in
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let cmd = "(claude mcp remove tado-use-bridge --scope user 2>/dev/null || true) && " +
                  "claude mcp add tado-use-bridge --scope user -- \(q(binaryPath)) 2>&1"
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
            .appendingPathComponent("Contents/MacOS/tado-use-bridge")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let release = cwd
            .appendingPathComponent(".build/release/tado-use-bridge")
        if FileManager.default.fileExists(atPath: release.path) {
            return release.path
        }
        let debug = cwd
            .appendingPathComponent(".build/debug/tado-use-bridge")
        if FileManager.default.fileExists(atPath: debug.path) {
            return debug.path
        }
        return debug.path
    }
}
