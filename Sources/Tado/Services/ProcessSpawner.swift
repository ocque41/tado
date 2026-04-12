import Foundation

enum ProcessSpawner {
    static func command(for todoText: String, engine: TerminalEngine, modeFlags: [String] = [], effortFlags: [String] = [], agentName: String? = nil) -> (executable: String, args: [String]) {
        let escaped = shellEscape(todoText)
        let cli = engine.rawValue
        var flags = modeFlags + effortFlags
        if let agentName, engine == .claude {
            flags.insert(contentsOf: ["--agent", agentName], at: 0)
        }
        let allFlags = flags.joined(separator: " ")
        let cmd = allFlags.isEmpty ? "\(cli) \(escaped)" : "\(cli) \(allFlags) \(escaped)"
        return ("/bin/zsh", ["-l", "-c", cmd])
    }

    static func shellEscape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    static func environment(
        sessionID: UUID,
        sessionName: String,
        engine: TerminalEngine,
        ipcRoot: URL
    ) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TADO_IPC_ROOT"] = ipcRoot.path
        env["TADO_SESSION_ID"] = sessionID.uuidString.lowercased()
        env["TADO_SESSION_NAME"] = sessionName
        env["TADO_ENGINE"] = engine.rawValue
        let binPath = ipcRoot.appendingPathComponent("bin").path
        if let existingPath = env["PATH"] {
            env["PATH"] = binPath + ":" + existingPath
        } else {
            env["PATH"] = binPath
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
