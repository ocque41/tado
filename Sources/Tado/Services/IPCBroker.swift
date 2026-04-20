import Foundation
import AppKit

@Observable
@MainActor
final class IPCBroker {
    let ipcRoot: URL
    private var watchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [UUID: Int32] = [:]
    private var externalWatcher: DispatchSourceFileSystemObject?
    private var externalFd: Int32?
    private var topicsWatcher: DispatchSourceFileSystemObject?
    private var topicsFd: Int32?
    private var topicMessageWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var topicMessageFds: [String: Int32] = [:]
    private var spawnWatcher: DispatchSourceFileSystemObject?
    private var spawnFd: Int32?
    /// Consolidated fallback poller. DispatchSource vnode watchers occasionally
    /// miss events on APFS under load; a single 3 s tick catches stranded
    /// messages across all three inbox kinds. Replaces three separate per-kind
    /// Timers that each woke the main thread.
    private var pollTimer: Timer?
    var onSpawnRequest: ((SpawnRequest) -> Void)?
    private weak var terminalManager: TerminalManager?
    private var processedFiles: Set<String> = []

    init(terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
        let pid = ProcessInfo.processInfo.processIdentifier
        self.ipcRoot = URL(fileURLWithPath: "/tmp/tado-ipc-\(pid)")

        createDirectoryStructure()
        writeHelperScripts()
        writeExternalScripts()
        installMCPServer()
        startExternalInboxWatcher()
        startTopicsWatcher()
        startSpawnRequestWatcher()
        startConsolidatedPoller()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cleanup()
            }
        }
    }

    // MARK: - Directory Setup

    private static let stableSymlink = URL(fileURLWithPath: "/tmp/tado-ipc")

    private func createDirectoryStructure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ipcRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: ipcRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: ipcRoot.appendingPathComponent("a2a-inbox"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: ipcRoot.appendingPathComponent("topics"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: ipcRoot.appendingPathComponent("spawn-requests"), withIntermediateDirectories: true)

        // Create stable symlink so external tools can find us
        let symlink = Self.stableSymlink
        try? fm.removeItem(at: symlink)
        try? fm.createSymbolicLink(at: symlink, withDestinationURL: ipcRoot)
    }

    private func createSessionDirectories(sessionID: UUID) {
        let fm = FileManager.default
        let base = ipcRoot.appendingPathComponent("sessions/\(sessionID.uuidString.lowercased())")
        try? fm.createDirectory(at: base.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: base.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        fm.createFile(atPath: base.appendingPathComponent("log").path, contents: nil)
    }

    // MARK: - Registry

    func registerSession(_ session: TerminalSession, engine: TerminalEngine) {
        createSessionDirectories(sessionID: session.id)
        updateRegistry()
        startWatching(session: session)
    }

    func unregisterSession(_ sessionID: UUID) {
        stopWatching(sessionID: sessionID)
        updateRegistry()
        // Clean up session directory
        let sessionDir = ipcRoot.appendingPathComponent("sessions/\(sessionID.uuidString.lowercased())")
        try? FileManager.default.removeItem(at: sessionDir)
    }

    func updateRegistry() {
        guard let manager = terminalManager else { return }
        let entries = manager.sessions.map { session in
            IPCSessionEntry(
                sessionID: session.id,
                name: session.todoText,
                engine: session.engine?.rawValue ?? "claude",
                gridLabel: CanvasLayout.gridLabel(forIndex: session.gridIndex),
                status: statusString(session.status),
                projectName: session.projectName,
                agentName: session.agentName,
                teamName: session.teamName,
                teamID: session.teamID?.uuidString.lowercased()
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: ipcRoot.appendingPathComponent("registry.json"), options: .atomic)
        }
    }

    private func statusString(_ status: SessionStatus) -> String {
        status.rawValue
    }

    // MARK: - File Watching

    func startWatching(session: TerminalSession) {
        let outboxURL = ipcRoot
            .appendingPathComponent("sessions")
            .appendingPathComponent(session.id.uuidString.lowercased())
            .appendingPathComponent("outbox")

        let fd = open(outboxURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let sessionID = session.id
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanOutbox(for: sessionID, at: outboxURL)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        watchers[session.id] = source
        fileDescriptors[session.id] = fd
    }

    func stopWatching(sessionID: UUID) {
        watchers[sessionID]?.cancel()
        watchers.removeValue(forKey: sessionID)
        fileDescriptors.removeValue(forKey: sessionID)
    }

    // MARK: - Message Processing

    private func scanOutbox(for sessionID: UUID, at outboxURL: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "msg" {
            let filename = file.lastPathComponent
            guard !processedFiles.contains(filename) else { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var message = try? decoder.decode(IPCMessage.self, from: data) else { continue }
            guard message.status == .pending else { continue }

            processedFiles.insert(filename)

            // Mark as delivered
            message.status = .delivered
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            if let updated = try? encoder.encode(message) {
                try? updated.write(to: file, options: .atomic)
            }

            // Copy to target inbox
            let inboxDir = ipcRoot
                .appendingPathComponent("sessions")
                .appendingPathComponent(message.to.uuidString.lowercased())
                .appendingPathComponent("inbox")
            try? fm.copyItem(at: file, to: inboxDir.appendingPathComponent(filename))

            deliverMessage(message)
        }
    }

    private func deliverMessage(_ message: IPCMessage) {
        guard let manager = terminalManager else { return }
        guard let targetSession = manager.sessions.first(where: { $0.id == message.to }) else { return }

        if message.fromName == "external" {
            // External sends: deliver as raw typed input
            targetSession.enqueueOrSend(message.body)
        } else {
            let formatted = "[From \"\(message.fromName)\"]: \(message.body)"
            targetSession.unreadMessageCount += 1
            targetSession.enqueueOrSend(formatted)
        }
        // Snippet for the notification body — first line, capped so
        // the system banner doesn't balloon on a multi-page paste.
        let snippet = message.body
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0.prefix(140)) } ?? ""
        EventBus.shared.publish(
            .ipcMessageReceived(
                sessionID: targetSession.id,
                title: targetSession.title,
                snippet: snippet,
                projectName: targetSession.projectName
            )
        )
    }

    // MARK: - Helper Scripts

    private func writeHelperScripts() {
        let binDir = ipcRoot.appendingPathComponent("bin")

        writeTadoSend(to: binDir)
        writeTadoRecv(to: binDir)
        writeTadoList(to: binDir)
        writeTadoBroadcast(to: binDir)
        writeTadoPublish(to: binDir)
        writeTadoSubscribe(to: binDir)
        writeTadoUnsubscribe(to: binDir)
        writeTadoTopics(to: binDir)
        writeTadoTeam(to: binDir)
        writeTadoDeploy(to: binDir)
    }

    private func writeTadoSend(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-send [--project <name>] <target-name-or-uuid> <message>

        PROJ_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            *) break ;;
          esac
        done

        TARGET="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TARGET" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-send [--project <name>] <target-name-or-id> <message>"
          echo "Use 'tado-list' to see available sessions"
          exit 1
        fi

        # Fall back to stable symlink when env vars are missing
        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"
        SESSION_NAME="${TADO_SESSION_NAME:-unknown}"

        RESOLVED=$(python3 - "$TARGET" "$IPC_ROOT/registry.json" "$SESSION_ID" "$PROJ_FILTER" <<'PYEOF'
        import json, sys
        target, registry, self_id = sys.argv[1], sys.argv[2], sys.argv[3].lower()
        proj_filter = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
        with open(registry) as f:
            entries = json.load(f)
        others = [e for e in entries if e['sessionID'].lower() != self_id] if self_id else entries
        if proj_filter:
            others = [e for e in others if (e.get('projectName') or '').lower() == proj_filter.lower()]
        t = target.lower()
        # Try exact UUID
        if len(t) == 36:
            for e in others:
                if e['sessionID'].lower() == t:
                    print(e['sessionID']); sys.exit(0)
        # Try grid coordinates: 1,1  1:1  [1,1]  [1, 1]
        cleaned = target.replace('[','').replace(']','').replace(' ','')
        for sep in [',',':']:
            if sep in cleaned:
                parts = cleaned.split(sep, 1)
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    label = f'[{parts[0]}, {parts[1]}]'
                    for e in others:
                        if e['gridLabel'] == label:
                            print(e['sessionID']); sys.exit(0)
                    break
        # Name substring
        for e in others:
            if t in e['name'].lower():
                print(e['sessionID']); sys.exit(0)
        sys.exit(1)
        PYEOF
        )
        if [ -z "$RESOLVED" ]; then
          echo "Error: No session found matching '$TARGET'"
          exit 1
        fi

        export TADO_MSGID=$(uuidgen | tr '[:upper:]' '[:lower:]')
        export TADO_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # If we have a session ID, write to our outbox; otherwise use a2a-inbox
        if [ -n "$SESSION_ID" ]; then
          python3 - "$MESSAGE" "$RESOLVED" "$IPC_ROOT" "$SESSION_ID" "$SESSION_NAME" <<'PYEOF'
        import json, sys, os, uuid
        msg = {
            'id': os.environ['TADO_MSGID'],
            'from': sys.argv[4],
            'fromName': sys.argv[5],
            'to': sys.argv[2],
            'timestamp': os.environ['TADO_TIMESTAMP'],
            'body': sys.argv[1],
            'status': 'pending'
        }
        outbox = os.path.join(sys.argv[3], 'sessions', sys.argv[4], 'outbox')
        with open(os.path.join(outbox, os.environ['TADO_MSGID'] + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        PYEOF
        else
          # No session ID — fall back to external a2a-inbox
          python3 - "$MESSAGE" "$RESOLVED" "$IPC_ROOT/a2a-inbox" <<'PYEOF'
        import json, sys, os, uuid
        from datetime import datetime, timezone
        msg_id = str(uuid.uuid4())
        msg = {
            'id': msg_id,
            'from': '00000000-0000-0000-0000-000000000000',
            'fromName': 'external',
            'to': sys.argv[2],
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'body': sys.argv[1],
            'status': 'pending'
        }
        with open(os.path.join(sys.argv[3], msg_id + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        PYEOF
        fi

        echo "Message sent to $RESOLVED"
        """

        let url = binDir.appendingPathComponent("tado-send")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoRecv(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-recv [--wait]

        INBOX="$TADO_IPC_ROOT/sessions/$TADO_SESSION_ID/inbox"

        if [ "$1" = "--wait" ]; then
          for i in $(seq 1 30); do
            COUNT=$(ls "$INBOX"/*.msg 2>/dev/null | wc -l | tr -d ' ')
            if [ "$COUNT" -gt 0 ]; then break; fi
            sleep 1
          done
        fi

        FOUND=0
        for msg in "$INBOX"/*.msg; do
          [ -f "$msg" ] || continue
          FOUND=1
          python3 - "$msg" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            m = json.load(f)
        print(f'From: {m["fromName"]}')
        print(f'Time: {m["timestamp"]}')
        print(f'Body: {m["body"]}')
        print('---')
        PYEOF
        done

        if [ "$FOUND" -eq 0 ]; then
          echo "No messages in inbox."
        fi
        """

        let url = binDir.appendingPathComponent("tado-recv")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoList(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Lists all peer sessions
        # Usage: tado-list [--project <name>] [--team <name>]

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        REGISTRY="$IPC_ROOT/registry.json"

        if [ ! -f "$REGISTRY" ]; then
          echo "No active sessions."
          exit 0
        fi

        PROJ_FILTER=""
        TEAM_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            --team) TEAM_FILTER="$2"; shift 2 ;;
            *) shift ;;
          esac
        done

        python3 - "$REGISTRY" "$TADO_SESSION_ID" "$PROJ_FILTER" "$TEAM_FILTER" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        self_id = sys.argv[2].lower() if len(sys.argv) > 2 and sys.argv[2] else ''
        proj_filter = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
        team_filter = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
        peers = [e for e in entries if e['sessionID'].lower() != self_id]
        if proj_filter:
            peers = [e for e in peers if (e.get('projectName') or '').lower() == proj_filter.lower()]
        if team_filter:
            peers = [e for e in peers if (e.get('teamName') or '').lower() == team_filter.lower()]
        if not peers:
            print('No matching sessions.')
        else:
            hdr = f'{"ID":<38} {"Engine":<8} {"Grid":<8} {"Status":<12} {"Project":<16} {"Team":<14} {"Agent":<14} Name'
            print(hdr)
            print('-' * 146)
            for e in peers:
                proj = e.get("projectName") or "-"
                team = e.get("teamName") or "-"
                agent = e.get("agentName") or "-"
                line = f'{e["sessionID"]:<38} {e["engine"]:<8} {e["gridLabel"]:<8} {e["status"]:<12} {proj:<16} {team:<14} {agent:<14} {e["name"]}'
                print(line)
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-list")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Tado A2A Inbox

    private func startExternalInboxWatcher() {
        let externalInboxURL = ipcRoot.appendingPathComponent("a2a-inbox")
        let fd = open(externalInboxURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanExternalInbox(at: externalInboxURL)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        externalWatcher = source
        externalFd = fd
    }

    private func scanExternalInbox(at inboxURL: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "msg" {
            let filename = file.lastPathComponent
            guard !processedFiles.contains("ext-\(filename)") else { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let message = try? decoder.decode(IPCMessage.self, from: data) else { continue }

            processedFiles.insert("ext-\(filename)")
            try? fm.removeItem(at: file)

            deliverMessage(message)
        }
    }

    // MARK: - Spawn Requests

    private func startSpawnRequestWatcher() {
        let spawnDir = ipcRoot.appendingPathComponent("spawn-requests")
        let fd = open(spawnDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanSpawnRequests()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        spawnWatcher = source
        spawnFd = fd
    }

    private func scanSpawnRequests() {
        let spawnDir = ipcRoot.appendingPathComponent("spawn-requests")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: spawnDir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "spawn" {
            let filename = file.lastPathComponent
            let key = "spawn-\(filename)"
            guard !processedFiles.contains(key) else { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var request = try? decoder.decode(SpawnRequest.self, from: data) else { continue }
            guard request.status == .pending else { continue }

            processedFiles.insert(key)

            // Mark as processing
            request.status = .processing
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            if let updated = try? encoder.encode(request) {
                try? updated.write(to: file, options: .atomic)
            }

            // Resolve defaults from requesting session if available
            if let requestedBy = request.requestedBy,
               let requesterUUID = UUID(uuidString: requestedBy),
               let requesterSession = terminalManager?.sessions.first(where: { $0.id == requesterUUID }) {
                var projectName = request.projectName
                var projectRoot = request.projectRoot
                var teamName = request.teamName
                var engine = request.engine
                if projectName == nil { projectName = requesterSession.projectName }
                if projectRoot == nil { projectRoot = requesterSession.projectRoot }
                if teamName == nil { teamName = requesterSession.teamName }
                if engine == nil { engine = requesterSession.engine?.rawValue }

                let resolved = SpawnRequest(
                    id: request.id,
                    prompt: request.prompt,
                    agentName: request.agentName,
                    teamName: teamName,
                    projectName: projectName,
                    projectRoot: projectRoot,
                    engine: engine,
                    requestedBy: request.requestedBy,
                    timestamp: request.timestamp,
                    status: request.status
                )
                onSpawnRequest?(resolved)
            } else {
                onSpawnRequest?(request)
            }

            // Mark as completed
            request.status = .completed
            if let updated = try? encoder.encode(request) {
                try? updated.write(to: file, options: .atomic)
            }

            // Clean up after delay
            let fileURL = file
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Tado A2A CLI Scripts

    private func writeExternalScripts() {
        let binDir = ipcRoot.appendingPathComponent("bin")
        writeExternalTadoList(to: binDir)
        writeExternalTadoSend(to: binDir)
        writeExternalTadoRead(to: binDir)
        writeExternalTadoBroadcast(to: binDir)
        writeExternalTadoPublish(to: binDir)
        writeExternalTadoSubscribe(to: binDir)
        writeExternalTadoUnsubscribe(to: binDir)
        writeExternalTadoTopics(to: binDir)
        writeExternalTadoDeploy(to: binDir)

        // Also install to ~/.local/bin for PATH accessibility
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        installScript(name: "tado-list", from: binDir, to: localBin)
        installScript(name: "tado-send", from: binDir, to: localBin)
        installScript(name: "tado-read", from: binDir, to: localBin)
        installScript(name: "tado-broadcast", from: binDir, to: localBin)
        installScript(name: "tado-publish", from: binDir, to: localBin)
        installScript(name: "tado-subscribe", from: binDir, to: localBin)
        installScript(name: "tado-unsubscribe", from: binDir, to: localBin)
        installScript(name: "tado-topics", from: binDir, to: localBin)
        installScript(name: "tado-deploy", from: binDir, to: localBin)

        // Packet 7 — settings / memory / notify CLIs. Share the same
        // `~/.local/bin` install target so users get them on $PATH
        // alongside the IPC tools.
        CLIConfigMemoryNotify.writeAll(to: binDir, localBin: localBin)
    }

    private func installMCPServer() {
        // Auto-register tado-mcp as a user-scope MCP server for Claude Code
        // so agents in any project can discover and use Tado's A2A tools.
        let claudeConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")

        // Check if already registered
        if let data = try? Data(contentsOf: claudeConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcpServers = json["mcpServers"] as? [String: Any],
           mcpServers["tado"] != nil {
            return // Already registered
        }

        // Find the tado-mcp server entry point relative to the app bundle or repo
        let candidates = [
            // Development: repo checkout
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("tado-mcp/dist/index.js"),
            // Installed alongside the app
            Bundle.main.resourceURL?
                .appendingPathComponent("tado-mcp/dist/index.js"),
        ].compactMap { $0 }

        guard let serverPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return // MCP server not found, skip
        }

        // Register via claude CLI if available
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["claude", "mcp", "add", "tado", "--scope", "user", "--", "node", serverPath.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private func installScript(name: String, from srcDir: URL, to destDir: URL) {
        let src = srcDir.appendingPathComponent("ext-\(name)")
        let dest = destDir.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: src, to: dest)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private func writeExternalTadoList(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Lists all Tado terminal sessions (run from any terminal)
        # Usage: tado-list [--project <name>] [--team <name>]

        IPC_ROOT="/tmp/tado-ipc"

        if [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ]; then
          echo "Tado is not running (no IPC root at $IPC_ROOT)"
          exit 1
        fi

        REGISTRY="$IPC_ROOT/registry.json"

        if [ ! -f "$REGISTRY" ]; then
          echo "No active sessions."
          exit 0
        fi

        PROJ_FILTER=""
        TEAM_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            --team) TEAM_FILTER="$2"; shift 2 ;;
            *) shift ;;
          esac
        done

        python3 - "$REGISTRY" "$PROJ_FILTER" "$TEAM_FILTER" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        proj_filter = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
        team_filter = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
        if proj_filter:
            entries = [e for e in entries if (e.get('projectName') or '').lower() == proj_filter.lower()]
        if team_filter:
            entries = [e for e in entries if (e.get('teamName') or '').lower() == team_filter.lower()]
        if not entries:
            print('No matching sessions.')
        else:
            hdr = f'{"ID":<38} {"Engine":<8} {"Grid":<8} {"Status":<12} {"Project":<16} {"Team":<14} {"Agent":<14} Name'
            print(hdr)
            print('-' * 146)
            for e in entries:
                proj = e.get("projectName") or "-"
                team = e.get("teamName") or "-"
                agent = e.get("agentName") or "-"
                line = f'{e["sessionID"]:<38} {e["engine"]:<8} {e["gridLabel"]:<8} {e["status"]:<12} {proj:<16} {team:<14} {agent:<14} {e["name"]}'
                print(line)
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-list")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoSend(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-send [--project <name>] <target-name-substring> <message>
        # Sends typed input to a Tado terminal session (run from any terminal)

        PROJ_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            *) break ;;
          esac
        done

        TARGET="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TARGET" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-send [--project <name>] <target-name-or-id> <message>"
          echo "Use 'tado-list' to see available sessions"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"

        if [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ]; then
          echo "Tado is not running (no IPC root at $IPC_ROOT)"
          exit 1
        fi

        REGISTRY="$IPC_ROOT/registry.json"

        RESOLVED=$(python3 - "$TARGET" "$REGISTRY" "$PROJ_FILTER" <<'PYEOF'
        import json, sys
        target = sys.argv[1]
        proj_filter = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
        with open(sys.argv[2]) as f:
            entries = json.load(f)
        if proj_filter:
            entries = [e for e in entries if (e.get('projectName') or '').lower() == proj_filter.lower()]
        t = target.lower()
        # Try exact UUID
        for e in entries:
            if e['sessionID'].lower() == t:
                print(e['sessionID']); sys.exit(0)
        # Try grid coordinates: 1,1  1:1  [1,1]  [1, 1]
        cleaned = target.replace('[','').replace(']','').replace(' ','')
        for sep in [',',':']:
            if sep in cleaned:
                parts = cleaned.split(sep, 1)
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    label = f'[{parts[0]}, {parts[1]}]'
                    for e in entries:
                        if e['gridLabel'] == label:
                            print(e['sessionID']); sys.exit(0)
                    break
        # Name substring
        matches = [e for e in entries if t in e['name'].lower()]
        if len(matches) == 1:
            print(matches[0]['sessionID']); sys.exit(0)
        elif len(matches) > 1:
            print('Multiple sessions match:', file=sys.stderr)
            for m in matches:
                print(f'  {m["sessionID"]}  {m["name"]}', file=sys.stderr)
            sys.exit(2)
        sys.exit(1)
        PYEOF
        )

        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 1 ]; then
          echo "Error: No session found matching '$TARGET'"
          exit 1
        elif [ $EXIT_CODE -eq 2 ]; then
          echo "Error: Multiple sessions match '$TARGET'. Be more specific."
          exit 1
        fi

        python3 - "$MESSAGE" "$RESOLVED" "$IPC_ROOT/a2a-inbox" <<'PYEOF'
        import json, sys, uuid
        from datetime import datetime, timezone
        msg_id = str(uuid.uuid4())
        msg = {
            'id': msg_id,
            'from': '00000000-0000-0000-0000-000000000000',
            'fromName': 'external',
            'to': sys.argv[2],
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'body': sys.argv[1],
            'status': 'pending'
        }
        import os
        with open(os.path.join(sys.argv[3], msg_id + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        PYEOF

        echo "Message sent to $RESOLVED"
        """

        let url = binDir.appendingPathComponent("ext-tado-send")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoRead(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Reads terminal output from a Tado session

        TARGET=""
        TAIL_LINES=""
        FOLLOW=false
        RAW=false

        while [ $# -gt 0 ]; do
          case "$1" in
            --tail|-n) TAIL_LINES="$2"; shift 2 ;;
            --follow|-f) FOLLOW=true; shift ;;
            --raw) RAW=true; shift ;;
            --help|-h)
              echo "Usage: tado-read <target> [--tail N] [--follow] [--raw]"
              echo "Use 'tado-list' to see available sessions"; exit 0 ;;
            *)
              if [ -z "$TARGET" ]; then TARGET="$1"; shift
              else echo "Unknown: $1"; exit 1; fi ;;
          esac
        done

        [ -z "$TARGET" ] && echo "Usage: tado-read <target> [--tail N] [--follow] [--raw]" && exit 1

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1

        REGISTRY="$IPC_ROOT/registry.json"
        [ ! -f "$REGISTRY" ] && echo "No active sessions." && exit 1

        RESOLVED=$(python3 - "$TARGET" "$REGISTRY" <<'PYEOF'
        import json, sys
        target = sys.argv[1]
        with open(sys.argv[2]) as f:
            entries = json.load(f)
        t = target.lower()
        for e in entries:
            if e['sessionID'].lower() == t:
                print(e['sessionID']); sys.exit(0)
        cleaned = target.replace('[','').replace(']','').replace(' ','')
        for sep in [',',':']:
            if sep in cleaned:
                parts = cleaned.split(sep, 1)
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    label = f'[{parts[0]}, {parts[1]}]'
                    for e in entries:
                        if e['gridLabel'] == label:
                            print(e['sessionID']); sys.exit(0)
                    break
        matches = [e for e in entries if t in e['name'].lower()]
        if len(matches) == 1:
            print(matches[0]['sessionID']); sys.exit(0)
        elif len(matches) > 1:
            for m in matches:
                print(f'  {m["sessionID"]}  {m["name"]}', file=sys.stderr)
            sys.exit(2)
        sys.exit(1)
        PYEOF
        )
        [ $? -ne 0 ] && echo "No session matching '$TARGET'" && exit 1

        SID=$(echo "$RESOLVED" | tr '[:upper:]' '[:lower:]')
        LOG="$IPC_ROOT/sessions/$SID/log"
        [ ! -f "$LOG" ] && echo "No output yet." && exit 0

        strip_batch() {
          python3 - "$1" <<'PYEOF'
        import sys
        with open(sys.argv[1], 'rb') as f:
            data = f.read().decode('utf-8', errors='replace')
        ESC, BEL = chr(27), chr(7)
        NL, CR, TAB = chr(10), chr(13), chr(9)
        out = []
        i = 0
        while i < len(data):
            c = data[i]
            if c == ESC:
                i += 1
                if i >= len(data): break
                c2 = data[i]
                if c2 == '[':
                    i += 1
                    while i < len(data) and not data[i].isalpha(): i += 1
                    if i < len(data): i += 1
                elif c2 == ']':
                    i += 1
                    while i < len(data):
                        if data[i] == BEL: i += 1; break
                        if data[i] == ESC and i+1 < len(data) and data[i+1] == chr(92): i += 2; break
                        i += 1
                else:
                    i += 1
            elif ord(c) < 32 and c not in (NL, TAB, CR):
                i += 1
            else:
                out.append(c); i += 1
        text = ''.join(out)
        lines = []
        for line in text.split(NL):
            if CR in line: line = line.rsplit(CR, 1)[-1]
            lines.append(line)
        text = NL.join(lines)
        while NL * 3 in text: text = text.replace(NL * 3, NL * 2)
        sys.stdout.write(text)
        PYEOF
        }

        strip_stream() {
          python3 -u -c '
        import sys
        ESC, BEL = chr(27), chr(7)
        CR = chr(13)
        for line in sys.stdin:
            out = []
            i = 0
            while i < len(line):
                c = line[i]
                if c == ESC:
                    i += 1
                    if i >= len(line): break
                    if line[i] == chr(91):
                        i += 1
                        while i < len(line) and not line[i].isalpha(): i += 1
                        if i < len(line): i += 1
                    elif line[i] == chr(93):
                        i += 1
                        while i < len(line) and line[i] != BEL: i += 1
                        if i < len(line): i += 1
                    else:
                        i += 1
                elif ord(c) < 32 and c not in (chr(10), chr(9), CR):
                    i += 1
                else:
                    out.append(c); i += 1
            result = "".join(out)
            if CR in result: result = result.rsplit(CR, 1)[-1]
            sys.stdout.write(result)
            sys.stdout.flush()
        '
        }

        if [ "$FOLLOW" = true ]; then
          if [ "$RAW" = true ]; then
            [ -n "$TAIL_LINES" ] && tail -n "$TAIL_LINES" -f "$LOG" || tail -f "$LOG"
          else
            ([ -n "$TAIL_LINES" ] && tail -n "$TAIL_LINES" -f "$LOG" || tail -f "$LOG") | strip_stream
          fi
        elif [ -n "$TAIL_LINES" ]; then
          [ "$RAW" = true ] && tail -n "$TAIL_LINES" "$LOG" || strip_batch "$LOG" | tail -n "$TAIL_LINES"
        else
          [ "$RAW" = true ] && cat "$LOG" || strip_batch "$LOG"
        fi
        """

        let url = binDir.appendingPathComponent("ext-tado-read")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Broadcast Script

    private func writeTadoBroadcast(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-broadcast [--project <name>] [--team <name>] <message>

        PROJ_FILTER=""
        TEAM_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            --team) TEAM_FILTER="$2"; shift 2 ;;
            *) break ;;
          esac
        done

        MESSAGE="$*"
        if [ -z "$MESSAGE" ]; then
          echo "Usage: tado-broadcast [--project <name>] [--team <name>] <message>"
          exit 1
        fi

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"
        SESSION_NAME="${TADO_SESSION_NAME:-unknown}"
        REGISTRY="$IPC_ROOT/registry.json"
        [ ! -f "$REGISTRY" ] && echo "No active sessions." && exit 0

        python3 - "$REGISTRY" "$SESSION_ID" "$SESSION_NAME" "$PROJ_FILTER" "$TEAM_FILTER" "$MESSAGE" "$IPC_ROOT" <<'PYEOF'
        import json, sys, os, uuid
        from datetime import datetime, timezone
        registry, self_id, self_name = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
        proj_filter = sys.argv[4] if sys.argv[4] else None
        team_filter = sys.argv[5] if sys.argv[5] else None
        message, ipc_root = sys.argv[6], sys.argv[7]
        with open(registry) as f:
            entries = json.load(f)
        targets = [e for e in entries if e['sessionID'].lower() != self_id]
        if proj_filter:
            targets = [e for e in targets if (e.get('projectName') or '').lower() == proj_filter.lower()]
        if team_filter:
            targets = [e for e in targets if (e.get('teamName') or '').lower() == team_filter.lower()]
        count = 0
        for e in targets:
            msg_id = str(uuid.uuid4())
            msg = {
                'id': msg_id,
                'from': self_id if self_id else '00000000-0000-0000-0000-000000000000',
                'fromName': self_name,
                'to': e['sessionID'],
                'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'body': message,
                'status': 'pending'
            }
            if self_id:
                outbox = os.path.join(ipc_root, 'sessions', self_id, 'outbox')
            else:
                outbox = os.path.join(ipc_root, 'a2a-inbox')
            with open(os.path.join(outbox, msg_id + '.msg'), 'w') as f:
                json.dump(msg, f, indent=2)
            count += 1
        print(f'Broadcast sent to {count} session(s)')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-broadcast")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoBroadcast(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-broadcast [--project <name>] [--team <name>] <message>

        PROJ_FILTER=""
        TEAM_FILTER=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_FILTER="$2"; shift 2 ;;
            --team) TEAM_FILTER="$2"; shift 2 ;;
            *) break ;;
          esac
        done

        MESSAGE="$*"
        if [ -z "$MESSAGE" ]; then
          echo "Usage: tado-broadcast [--project <name>] [--team <name>] <message>"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1
        REGISTRY="$IPC_ROOT/registry.json"
        [ ! -f "$REGISTRY" ] && echo "No active sessions." && exit 0

        python3 - "$REGISTRY" "$PROJ_FILTER" "$TEAM_FILTER" "$MESSAGE" "$IPC_ROOT" <<'PYEOF'
        import json, sys, os, uuid
        from datetime import datetime, timezone
        registry = sys.argv[1]
        proj_filter = sys.argv[2] if sys.argv[2] else None
        team_filter = sys.argv[3] if sys.argv[3] else None
        message, ipc_root = sys.argv[4], sys.argv[5]
        with open(registry) as f:
            entries = json.load(f)
        if proj_filter:
            entries = [e for e in entries if (e.get('projectName') or '').lower() == proj_filter.lower()]
        if team_filter:
            entries = [e for e in entries if (e.get('teamName') or '').lower() == team_filter.lower()]
        count = 0
        for e in entries:
            msg_id = str(uuid.uuid4())
            msg = {
                'id': msg_id,
                'from': '00000000-0000-0000-0000-000000000000',
                'fromName': 'external',
                'to': e['sessionID'],
                'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'body': message,
                'status': 'pending'
            }
            with open(os.path.join(ipc_root, 'a2a-inbox', msg_id + '.msg'), 'w') as f:
                json.dump(msg, f, indent=2)
            count += 1
        print(f'Broadcast sent to {count} session(s)')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-broadcast")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Publish/Subscribe Scripts

    private func writeTadoPublish(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-publish <topic> <message>

        TOPIC="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TOPIC" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-publish <topic> <message>"
          exit 1
        fi

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-00000000-0000-0000-0000-000000000000}"
        SESSION_NAME="${TADO_SESSION_NAME:-unknown}"
        TOPIC_DIR="$IPC_ROOT/topics/$TOPIC/messages"
        mkdir -p "$TOPIC_DIR"

        python3 - "$TOPIC" "$MESSAGE" "$SESSION_ID" "$SESSION_NAME" "$TOPIC_DIR" <<'PYEOF'
        import json, sys, uuid
        from datetime import datetime, timezone
        topic, message, sid, sname, topic_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        msg_id = str(uuid.uuid4())
        msg = {
            'id': msg_id,
            'from': sid,
            'fromName': sname,
            'topic': topic,
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'body': message
        }
        import os
        with open(os.path.join(topic_dir, msg_id + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        print(f'Published to topic "{topic}"')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-publish")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoPublish(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-publish <topic> <message>

        TOPIC="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TOPIC" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-publish <topic> <message>"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1
        TOPIC_DIR="$IPC_ROOT/topics/$TOPIC/messages"
        mkdir -p "$TOPIC_DIR"

        python3 - "$TOPIC" "$MESSAGE" "$TOPIC_DIR" <<'PYEOF'
        import json, sys, uuid
        from datetime import datetime, timezone
        topic, message, topic_dir = sys.argv[1], sys.argv[2], sys.argv[3]
        msg_id = str(uuid.uuid4())
        msg = {
            'id': msg_id,
            'from': '00000000-0000-0000-0000-000000000000',
            'fromName': 'external',
            'topic': topic,
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'body': message
        }
        import os
        with open(os.path.join(topic_dir, msg_id + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        print(f'Published to topic "{topic}"')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-publish")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoSubscribe(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-subscribe <topic> [--project <name>]

        TOPIC=""
        PROJ_NAME=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_NAME="$2"; shift 2 ;;
            *) if [ -z "$TOPIC" ]; then TOPIC="$1"; fi; shift ;;
          esac
        done

        if [ -z "$TOPIC" ]; then
          echo "Usage: tado-subscribe <topic> [--project <name>]"
          exit 1
        fi

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"
        SUBS_DIR="$IPC_ROOT/topics/$TOPIC"
        mkdir -p "$SUBS_DIR"

        python3 - "$SUBS_DIR/subscribers.json" "$SESSION_ID" "$PROJ_NAME" <<'PYEOF'
        import json, sys, os
        subs_file, session_id, proj_name = sys.argv[1], sys.argv[2], sys.argv[3]
        subs = []
        if os.path.exists(subs_file):
            with open(subs_file) as f:
                subs = json.load(f)
        if proj_name:
            entry = {'type': 'project', 'id': None, 'name': proj_name}
            key = ('project', proj_name.lower())
        elif session_id:
            entry = {'type': 'session', 'id': session_id, 'name': None}
            key = ('session', session_id.lower())
        else:
            print('Error: no session ID or project name'); sys.exit(1)
        existing = set()
        for s in subs:
            existing.add((s['type'], (s.get('id') or s.get('name') or '').lower()))
        if key not in existing:
            subs.append(entry)
            with open(subs_file, 'w') as f:
                json.dump(subs, f, indent=2)
            print(f'Subscribed to topic')
        else:
            print(f'Already subscribed')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-subscribe")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoSubscribe(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-subscribe <topic> [--project <name>]

        TOPIC=""
        PROJ_NAME=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project) PROJ_NAME="$2"; shift 2 ;;
            *) if [ -z "$TOPIC" ]; then TOPIC="$1"; fi; shift ;;
          esac
        done

        if [ -z "$TOPIC" ]; then
          echo "Usage: tado-subscribe <topic> [--project <name>]"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1
        SESSION_ID="${TADO_SESSION_ID:-}"
        SUBS_DIR="$IPC_ROOT/topics/$TOPIC"
        mkdir -p "$SUBS_DIR"

        python3 - "$SUBS_DIR/subscribers.json" "$SESSION_ID" "$PROJ_NAME" <<'PYEOF'
        import json, sys, os
        subs_file, session_id, proj_name = sys.argv[1], sys.argv[2], sys.argv[3]
        subs = []
        if os.path.exists(subs_file):
            with open(subs_file) as f:
                subs = json.load(f)
        if proj_name:
            entry = {'type': 'project', 'id': None, 'name': proj_name}
            key = ('project', proj_name.lower())
        elif session_id:
            entry = {'type': 'session', 'id': session_id, 'name': None}
            key = ('session', session_id.lower())
        else:
            print('Error: no session ID or project name'); sys.exit(1)
        existing = set()
        for s in subs:
            existing.add((s['type'], (s.get('id') or s.get('name') or '').lower()))
        if key not in existing:
            subs.append(entry)
            with open(subs_file, 'w') as f:
                json.dump(subs, f, indent=2)
            print(f'Subscribed to topic')
        else:
            print(f'Already subscribed')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-subscribe")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoUnsubscribe(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-unsubscribe <topic>

        TOPIC="$1"
        if [ -z "$TOPIC" ]; then
          echo "Usage: tado-unsubscribe <topic>"
          exit 1
        fi

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"
        SUBS_FILE="$IPC_ROOT/topics/$TOPIC/subscribers.json"

        [ ! -f "$SUBS_FILE" ] && echo "Not subscribed to '$TOPIC'" && exit 0

        python3 - "$SUBS_FILE" "$SESSION_ID" <<'PYEOF'
        import json, sys
        subs_file, session_id = sys.argv[1], sys.argv[2].lower()
        with open(subs_file) as f:
            subs = json.load(f)
        before = len(subs)
        subs = [s for s in subs if not (s['type'] == 'session' and (s.get('id') or '').lower() == session_id)]
        if len(subs) < before:
            with open(subs_file, 'w') as f:
                json.dump(subs, f, indent=2)
            print('Unsubscribed')
        else:
            print('Not subscribed')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-unsubscribe")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoUnsubscribe(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-unsubscribe <topic>

        TOPIC="$1"
        if [ -z "$TOPIC" ]; then
          echo "Usage: tado-unsubscribe <topic>"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1
        SESSION_ID="${TADO_SESSION_ID:-}"
        SUBS_FILE="$IPC_ROOT/topics/$TOPIC/subscribers.json"

        [ ! -f "$SUBS_FILE" ] && echo "Not subscribed to '$TOPIC'" && exit 0

        python3 - "$SUBS_FILE" "$SESSION_ID" <<'PYEOF'
        import json, sys
        subs_file, session_id = sys.argv[1], sys.argv[2].lower()
        with open(subs_file) as f:
            subs = json.load(f)
        before = len(subs)
        subs = [s for s in subs if not (s['type'] == 'session' and (s.get('id') or '').lower() == session_id)]
        if len(subs) < before:
            with open(subs_file, 'w') as f:
                json.dump(subs, f, indent=2)
            print('Unsubscribed')
        else:
            print('Not subscribed')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-unsubscribe")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoTopics(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Lists all topics with subscriber counts

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        TOPICS_DIR="$IPC_ROOT/topics"

        if [ ! -d "$TOPICS_DIR" ]; then
          echo "No topics."
          exit 0
        fi

        python3 - "$TOPICS_DIR" <<'PYEOF'
        import os, json, sys
        topics_dir = sys.argv[1]
        topics = [d for d in os.listdir(topics_dir) if os.path.isdir(os.path.join(topics_dir, d))]
        if not topics:
            print('No topics.')
        else:
            print(f'{"Topic":<30} {"Subscribers":<15} Messages')
            print('-' * 60)
            for t in sorted(topics):
                subs_file = os.path.join(topics_dir, t, 'subscribers.json')
                subs = 0
                if os.path.exists(subs_file):
                    with open(subs_file) as f:
                        subs = len(json.load(f))
                msgs_dir = os.path.join(topics_dir, t, 'messages')
                msgs = len([f for f in os.listdir(msgs_dir) if f.endswith('.msg')]) if os.path.exists(msgs_dir) else 0
                print(f'{t:<30} {subs:<15} {msgs}')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-topics")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoTopics(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Lists all topics with subscriber counts

        IPC_ROOT="/tmp/tado-ipc"
        [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ] && echo "Tado is not running" && exit 1
        TOPICS_DIR="$IPC_ROOT/topics"

        if [ ! -d "$TOPICS_DIR" ]; then
          echo "No topics."
          exit 0
        fi

        python3 - "$TOPICS_DIR" <<'PYEOF'
        import os, json, sys
        topics_dir = sys.argv[1]
        topics = [d for d in os.listdir(topics_dir) if os.path.isdir(os.path.join(topics_dir, d))]
        if not topics:
            print('No topics.')
        else:
            print(f'{"Topic":<30} {"Subscribers":<15} Messages')
            print('-' * 60)
            for t in sorted(topics):
                subs_file = os.path.join(topics_dir, t, 'subscribers.json')
                subs = 0
                if os.path.exists(subs_file):
                    with open(subs_file) as f:
                        subs = len(json.load(f))
                msgs_dir = os.path.join(topics_dir, t, 'messages')
                msgs = len([f for f in os.listdir(msgs_dir) if f.endswith('.msg')]) if os.path.exists(msgs_dir) else 0
                print(f'{t:<30} {subs:<15} {msgs}')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-topics")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeExternalTadoDeploy(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]
        # Deploys a new agent session on the Tado canvas (run from any terminal).

        AGENT=""
        TEAM=""
        PROJECT=""
        ENGINE=""
        CWD=""
        PROMPT=""

        while [ $# -gt 0 ]; do
          case "$1" in
            --agent) AGENT="$2"; shift 2 ;;
            --team) TEAM="$2"; shift 2 ;;
            --project) PROJECT="$2"; shift 2 ;;
            --engine) ENGINE="$2"; shift 2 ;;
            --cwd) CWD="$2"; shift 2 ;;
            --help|-h)
              echo "Usage: tado-deploy \\"<prompt>\\" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]"
              exit 0
              ;;
            *) [ -z "$PROMPT" ] && PROMPT="$1" || PROMPT="$PROMPT $1"; shift ;;
          esac
        done

        if [ -z "$PROMPT" ]; then
          echo "Usage: tado-deploy \\"<prompt>\\" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"

        if [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ]; then
          echo "Tado is not running (no IPC root at $IPC_ROOT)"
          exit 1
        fi

        SPAWN_DIR="$IPC_ROOT/spawn-requests"
        mkdir -p "$SPAWN_DIR"

        python3 - "$PROMPT" "$AGENT" "$TEAM" "$PROJECT" "$CWD" "$ENGINE" "$SPAWN_DIR" <<'PYEOF'
        import json, sys, uuid, os
        from datetime import datetime, timezone

        prompt = sys.argv[1]
        agent = sys.argv[2] or None
        team = sys.argv[3] or None
        project = sys.argv[4] or None
        cwd = sys.argv[5] or None
        engine = sys.argv[6] or None
        spawn_dir = sys.argv[7]

        req_id = str(uuid.uuid4())
        request = {
            'id': req_id,
            'prompt': prompt,
            'agentName': agent,
            'teamName': team,
            'projectName': project,
            'projectRoot': cwd,
            'engine': engine,
            'requestedBy': None,
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'status': 'pending'
        }

        path = os.path.join(spawn_dir, req_id + '.spawn')
        with open(path, 'w') as f:
            json.dump(request, f, indent=2)

        print(f'Deploy request submitted: {req_id}')
        if agent:
            print(f'  Agent: {agent}')
        if project:
            print(f'  Project: {project}')
        PYEOF
        """

        let url = binDir.appendingPathComponent("ext-tado-deploy")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Team Script

    private func writeTadoTeam(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-team [--send <message>]
        # Without --send: lists team members
        # With --send: sends message to all teammates

        SEND_MSG=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --send) shift; SEND_MSG="$*"; break ;;
            *) shift ;;
          esac
        done

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"
        SESSION_NAME="${TADO_SESSION_NAME:-unknown}"
        TEAM_NAME="${TADO_TEAM_NAME:-}"
        REGISTRY="$IPC_ROOT/registry.json"

        if [ -z "$TEAM_NAME" ]; then
          echo "Not part of a team. Use tado-list to see sessions."
          exit 1
        fi

        if [ -z "$SEND_MSG" ]; then
          # List team members
          python3 - "$REGISTRY" "$SESSION_ID" "$TEAM_NAME" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        self_id = sys.argv[2].lower()
        team_name = sys.argv[3].lower()
        members = [e for e in entries if (e.get('teamName') or '').lower() == team_name]
        print(f'Team: {sys.argv[3]} ({len(members)} members)')
        print('-' * 80)
        for e in members:
            marker = ' (you)' if e['sessionID'].lower() == self_id else ''
            agent = e.get('agentName') or '-'
            print(f'  {e["gridLabel"]:<8} {agent:<14} {e["status"]:<12} {e["name"]}{marker}')
        PYEOF
        else
          # Send to all teammates
          python3 - "$REGISTRY" "$SESSION_ID" "$SESSION_NAME" "$TEAM_NAME" "$SEND_MSG" "$IPC_ROOT" <<'PYEOF'
        import json, sys, os, uuid
        from datetime import datetime, timezone
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        self_id, self_name = sys.argv[2].lower(), sys.argv[3]
        team_name, message, ipc_root = sys.argv[4].lower(), sys.argv[5], sys.argv[6]
        teammates = [e for e in entries if (e.get('teamName') or '').lower() == team_name and e['sessionID'].lower() != self_id]
        count = 0
        for e in teammates:
            msg_id = str(uuid.uuid4())
            msg = {
                'id': msg_id,
                'from': self_id,
                'fromName': self_name,
                'to': e['sessionID'],
                'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'body': message,
                'status': 'pending'
            }
            if self_id and self_id != '00000000-0000-0000-0000-000000000000':
                outbox = os.path.join(ipc_root, 'sessions', self_id, 'outbox')
            else:
                outbox = os.path.join(ipc_root, 'a2a-inbox')
            with open(os.path.join(outbox, msg_id + '.msg'), 'w') as f:
                json.dump(msg, f, indent=2)
            count += 1
        print(f'Sent to {count} teammate(s)')
        PYEOF
        fi
        """

        let url = binDir.appendingPathComponent("tado-team")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeTadoDeploy(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]
        # Deploys a new agent session on the Tado canvas.

        AGENT=""
        TEAM=""
        PROJECT=""
        ENGINE=""
        CWD=""
        PROMPT=""

        while [ $# -gt 0 ]; do
          case "$1" in
            --agent) AGENT="$2"; shift 2 ;;
            --team) TEAM="$2"; shift 2 ;;
            --project) PROJECT="$2"; shift 2 ;;
            --engine) ENGINE="$2"; shift 2 ;;
            --cwd) CWD="$2"; shift 2 ;;
            --help|-h)
              echo "Usage: tado-deploy \\"<prompt>\\" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]"
              echo ""
              echo "Deploys a new agent session on the Tado canvas."
              echo ""
              echo "Options:"
              echo "  --agent    Agent definition name (from .claude/agents/<name>.md)"
              echo "  --team     Team name (defaults to TADO_TEAM_NAME)"
              echo "  --project  Project name (defaults to TADO_PROJECT_NAME)"
              echo "  --engine   Engine: claude or codex (defaults to TADO_ENGINE)"
              echo "  --cwd      Working directory for the new session (defaults to TADO_PROJECT_ROOT)"
              exit 0
              ;;
            *) [ -z "$PROMPT" ] && PROMPT="$1" || PROMPT="$PROMPT $1"; shift ;;
          esac
        done

        if [ -z "$PROMPT" ]; then
          echo "Usage: tado-deploy \\"<prompt>\\" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]"
          exit 1
        fi

        IPC_ROOT="${TADO_IPC_ROOT:-/tmp/tado-ipc}"
        SESSION_ID="${TADO_SESSION_ID:-}"

        # Apply env defaults for unset flags
        [ -z "$TEAM" ] && TEAM="${TADO_TEAM_NAME:-}"
        [ -z "$PROJECT" ] && PROJECT="${TADO_PROJECT_NAME:-}"
        [ -z "$ENGINE" ] && ENGINE="${TADO_ENGINE:-}"
        [ -z "$CWD" ] && CWD="${TADO_PROJECT_ROOT:-}"

        if [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ]; then
          echo "Tado is not running (no IPC root at $IPC_ROOT)"
          exit 1
        fi

        SPAWN_DIR="$IPC_ROOT/spawn-requests"
        mkdir -p "$SPAWN_DIR"

        python3 - "$PROMPT" "$AGENT" "$TEAM" "$PROJECT" "$CWD" "$ENGINE" "$SESSION_ID" "$SPAWN_DIR" <<'PYEOF'
        import json, sys, uuid, os
        from datetime import datetime, timezone

        prompt = sys.argv[1]
        agent = sys.argv[2] or None
        team = sys.argv[3] or None
        project = sys.argv[4] or None
        cwd = sys.argv[5] or None
        engine = sys.argv[6] or None
        requested_by = sys.argv[7] or None
        spawn_dir = sys.argv[8]

        req_id = str(uuid.uuid4())
        request = {
            'id': req_id,
            'prompt': prompt,
            'agentName': agent,
            'teamName': team,
            'projectName': project,
            'projectRoot': cwd,
            'engine': engine,
            'requestedBy': requested_by,
            'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'status': 'pending'
        }

        path = os.path.join(spawn_dir, req_id + '.spawn')
        with open(path, 'w') as f:
            json.dump(request, f, indent=2)

        print(f'Deploy request submitted: {req_id}')
        if agent:
            print(f'  Agent: {agent}')
        if team:
            print(f'  Team: {team}')
        if project:
            print(f'  Project: {project}')
        PYEOF
        """

        let url = binDir.appendingPathComponent("tado-deploy")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Topics Broker

    private func startTopicsWatcher() {
        let topicsURL = ipcRoot.appendingPathComponent("topics")
        let fd = open(topicsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanForNewTopics()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        topicsWatcher = source
        topicsFd = fd
    }

    /// Single fallback poller replacing the three per-subsystem 2–3 s timers.
    /// Runs on main at 3 s intervals; each scan is cheap when no new files
    /// exist. Reduces idle main-thread wake-rate from 3 separate timers to 1.
    private func startConsolidatedPoller() {
        let externalInboxURL = ipcRoot.appendingPathComponent("a2a-inbox")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.scanExternalInbox(at: externalInboxURL)
                self.scanSpawnRequests()
                self.scanForNewTopics()
                self.scanAllTopicMessages()
            }
        }
    }

    private func scanForNewTopics() {
        let topicsURL = ipcRoot.appendingPathComponent("topics")
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: topicsURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let topicName = dir.lastPathComponent
            guard topicMessageWatchers[topicName] == nil else { continue }
            startWatchingTopic(name: topicName)
        }
    }

    private func startWatchingTopic(name: String) {
        let messagesURL = ipcRoot.appendingPathComponent("topics/\(name)/messages")
        let fm = FileManager.default
        try? fm.createDirectory(at: messagesURL, withIntermediateDirectories: true)

        let fd = open(messagesURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scanTopicMessages(topic: name, at: messagesURL)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        topicMessageWatchers[name] = source
        topicMessageFds[name] = fd
    }

    private func scanAllTopicMessages() {
        let topicsURL = ipcRoot.appendingPathComponent("topics")
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: topicsURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let topicName = dir.lastPathComponent
            let messagesURL = dir.appendingPathComponent("messages")
            scanTopicMessages(topic: topicName, at: messagesURL)
        }
    }

    private func scanTopicMessages(topic: String, at messagesURL: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: messagesURL, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "msg" {
            let filename = file.lastPathComponent
            let key = "topic-\(topic)-\(filename)"
            guard !processedFiles.contains(key) else { continue }

            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let topicMsg = try? decoder.decode(TopicMessage.self, from: data) else { continue }

            processedFiles.insert(key)

            let subscribers = resolveSubscribers(topic: topic)
            for subscriberID in subscribers where subscriberID != topicMsg.from {
                let ipcMessage = IPCMessage(
                    id: UUID(),
                    from: topicMsg.from,
                    fromName: "topic:\(topic)",
                    to: subscriberID,
                    timestamp: topicMsg.timestamp,
                    body: topicMsg.body,
                    status: .pending
                )
                deliverMessage(ipcMessage)
            }

            try? fm.removeItem(at: file)
        }
    }

    private func resolveSubscribers(topic: String) -> [UUID] {
        let subsFile = ipcRoot.appendingPathComponent("topics/\(topic)/subscribers.json")
        guard let data = try? Data(contentsOf: subsFile) else { return [] }
        guard let subscribers = try? JSONDecoder().decode([TopicSubscriber].self, from: data) else { return [] }

        var resolved: Set<UUID> = []
        guard let manager = terminalManager else { return [] }

        for sub in subscribers {
            switch sub.type {
            case .session:
                if let idStr = sub.id, let uuid = UUID(uuidString: idStr) {
                    if manager.sessions.contains(where: { $0.id == uuid }) {
                        resolved.insert(uuid)
                    }
                }
            case .project:
                if let projectName = sub.name {
                    for session in manager.sessions where session.projectName?.lowercased() == projectName.lowercased() {
                        resolved.insert(session.id)
                    }
                }
            }
        }

        return Array(resolved)
    }

    // MARK: - Cleanup

    func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        spawnWatcher?.cancel()
        spawnWatcher = nil
        spawnFd = nil
        topicsWatcher?.cancel()
        topicsWatcher = nil
        topicsFd = nil
        for (_, watcher) in topicMessageWatchers {
            watcher.cancel()
        }
        topicMessageWatchers.removeAll()
        topicMessageFds.removeAll()
        externalWatcher?.cancel()
        externalWatcher = nil
        externalFd = nil
        for (id, _) in watchers {
            stopWatching(sessionID: id)
        }
        try? FileManager.default.removeItem(at: ipcRoot)
        try? FileManager.default.removeItem(at: Self.stableSymlink)
    }
}
