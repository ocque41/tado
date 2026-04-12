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
    private weak var terminalManager: TerminalManager?
    private var processedFiles: Set<String> = []

    init(terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
        let pid = ProcessInfo.processInfo.processIdentifier
        self.ipcRoot = URL(fileURLWithPath: "/tmp/tado-ipc-\(pid)")

        createDirectoryStructure()
        writeHelperScripts()
        writeExternalScripts()
        startExternalInboxWatcher()

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
                status: statusString(session.status)
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
    }

    // MARK: - Helper Scripts

    private func writeHelperScripts() {
        let binDir = ipcRoot.appendingPathComponent("bin")

        writeTadoSend(to: binDir)
        writeTadoRecv(to: binDir)
        writeTadoList(to: binDir)
    }

    private func writeTadoSend(to binDir: URL) {
        let script = """
        #!/bin/bash
        # Usage: tado-send <target-name-or-uuid> <message>

        TARGET="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TARGET" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-send <target-name-or-id> <message>"
          echo "Use 'tado-list' to see available sessions"
          exit 1
        fi

        RESOLVED=$(python3 - "$TARGET" "$TADO_IPC_ROOT/registry.json" "$TADO_SESSION_ID" <<'PYEOF'
        import json, sys
        target, registry, self_id = sys.argv[1], sys.argv[2], sys.argv[3].lower()
        with open(registry) as f:
            entries = json.load(f)
        others = [e for e in entries if e['sessionID'].lower() != self_id]
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

        python3 - "$MESSAGE" "$RESOLVED" <<'PYEOF'
        import json, sys, os
        msg = {
            'id': os.environ['TADO_MSGID'],
            'from': os.environ['TADO_SESSION_ID'],
            'fromName': os.environ.get('TADO_SESSION_NAME', 'unknown'),
            'to': sys.argv[2],
            'timestamp': os.environ['TADO_TIMESTAMP'],
            'body': sys.argv[1],
            'status': 'pending'
        }
        outbox = os.path.join(os.environ['TADO_IPC_ROOT'], 'sessions', os.environ['TADO_SESSION_ID'], 'outbox')
        with open(os.path.join(outbox, os.environ['TADO_MSGID'] + '.msg'), 'w') as f:
            json.dump(msg, f, indent=2)
        PYEOF

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

        REGISTRY="$TADO_IPC_ROOT/registry.json"

        if [ ! -f "$REGISTRY" ]; then
          echo "No active sessions."
          exit 0
        fi

        python3 - "$REGISTRY" "$TADO_SESSION_ID" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        self_id = sys.argv[2].lower() if len(sys.argv) > 2 else ''
        peers = [e for e in entries if e['sessionID'].lower() != self_id]
        if not peers:
            print('No other sessions active.')
        else:
            hdr = f'{"ID":<38} {"Engine":<8} {"Grid":<8} {"Status":<12} Name'
            print(hdr)
            print('-' * 100)
            for e in peers:
                line = f'{e["sessionID"]:<38} {e["engine"]:<8} {e["gridLabel"]:<8} {e["status"]:<12} {e["name"]}'
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

    // MARK: - Tado A2A CLI Scripts

    private func writeExternalScripts() {
        let binDir = ipcRoot.appendingPathComponent("bin")
        writeExternalTadoList(to: binDir)
        writeExternalTadoSend(to: binDir)
        writeExternalTadoRead(to: binDir)

        // Also install to ~/.local/bin for PATH accessibility
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        installScript(name: "tado-list", from: binDir, to: localBin)
        installScript(name: "tado-send", from: binDir, to: localBin)
        installScript(name: "tado-read", from: binDir, to: localBin)
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

        python3 - "$REGISTRY" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            entries = json.load(f)
        if not entries:
            print('No active sessions.')
        else:
            hdr = f'{"ID":<38} {"Engine":<8} {"Grid":<8} {"Status":<12} Name'
            print(hdr)
            print('-' * 100)
            for e in entries:
                line = f'{e["sessionID"]:<38} {e["engine"]:<8} {e["gridLabel"]:<8} {e["status"]:<12} {e["name"]}'
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
        # Usage: tado-send <target-name-substring> <message>
        # Sends typed input to a Tado terminal session (run from any terminal)

        TARGET="$1"
        shift
        MESSAGE="$*"

        if [ -z "$TARGET" ] || [ -z "$MESSAGE" ]; then
          echo "Usage: tado-send <target-name-or-id> <message>"
          echo "Use 'tado-list' to see available sessions"
          exit 1
        fi

        IPC_ROOT="/tmp/tado-ipc"

        if [ ! -L "$IPC_ROOT" ] && [ ! -d "$IPC_ROOT" ]; then
          echo "Tado is not running (no IPC root at $IPC_ROOT)"
          exit 1
        fi

        REGISTRY="$IPC_ROOT/registry.json"

        # Resolve target: try UUID, then grid coords (1,1 / 1:1 / [1,1]), then name substring
        RESOLVED=$(python3 - "$TARGET" "$REGISTRY" <<'PYEOF'
        import json, sys
        target = sys.argv[1]
        with open(sys.argv[2]) as f:
            entries = json.load(f)
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

    // MARK: - Cleanup

    func cleanup() {
        externalWatcher?.cancel()
        externalWatcher = nil
        externalFd = nil
        for (id, _) in watchers {
            stopWatching(sessionID: id)
        }
        try? FileManager.default.removeItem(at: ipcRoot)
        // Remove stable symlink
        try? FileManager.default.removeItem(at: Self.stableSymlink)
    }
}
