import Foundation

/// Generates the three Tado CLI tools delivered in Packet 7:
/// `tado-config`, `tado-notify`, `tado-memory`. They sit alongside
/// the existing `tado-list` / `tado-send` / `tado-read` / `tado-deploy`
/// in `/tmp/tado-ipc/bin/` and are symlinked into `~/.local/bin/`
/// for PATH-accessibility.
///
/// All three write through the same atomic-store discipline as the
/// Swift app (flock + tmp + rename) so concurrent writes from the
/// app + a terminal + a bash hook don't tear. Locks live next to
/// their targets as `<target>.lock` files — matching Swift
/// `AtomicStore`'s convention exactly.
///
/// `tado-config` uses python3 (always present on macOS) for JSON
/// path manipulation; `tado-notify` writes a single NDJSON line to
/// `events/current.ndjson`; `tado-memory` manipulates plain markdown
/// files.
enum CLIConfigMemoryNotify {
    /// Write all three scripts to `binDir` and install a copy to
    /// `localBin`. Idempotent — overwrites existing files so upgrades
    /// pick up fresh templates each launch.
    static func writeAll(to binDir: URL, localBin: URL) {
        writeTadoConfig(to: binDir)
        writeTadoNotify(to: binDir)
        writeTadoMemory(to: binDir)
        install("tado-config", from: binDir, to: localBin)
        install("tado-notify", from: binDir, to: localBin)
        install("tado-memory", from: binDir, to: localBin)
    }

    // MARK: - tado-config

    private static func writeTadoConfig(to binDir: URL) {
        let script = #"""
        #!/bin/bash
        # Tado settings CLI. Reads + writes ~/Library/Application Support/Tado/settings/global.json
        # and <cwd>/.tado/{config,local}.json with the same atomic flock+rename
        # discipline as the Swift app.

        set -e

        GLOBAL="$HOME/Library/Application Support/Tado/settings/global.json"

        find_project_root() {
            dir="$PWD"
            while [ "$dir" != "/" ]; do
                if [ -d "$dir/.tado" ]; then echo "$dir"; return; fi
                dir="$(dirname "$dir")"
            done
            return 1
        }

        scope_path() {
            case "$1" in
                global)         echo "$GLOBAL" ;;
                project|project-shared)
                    root="$(find_project_root)" || { echo "no .tado/ found above $PWD" >&2; exit 2; }
                    echo "$root/.tado/config.json" ;;
                project-local|local)
                    root="$(find_project_root)" || { echo "no .tado/ found above $PWD" >&2; exit 2; }
                    echo "$root/.tado/local.json" ;;
                *) echo "unknown scope: $1" >&2; exit 2 ;;
            esac
        }

        atomic_write() {
            target="$1"; payload="$2"
            lock="${target}.lock"
            tmp="${target}.tmp-$$"
            mkdir -p "$(dirname "$target")"
            # flock with exclusive; wait forever (acceptable on user-driven calls).
            (
                flock 9
                printf '%s' "$payload" > "$tmp"
                mv -f "$tmp" "$target"
            ) 9>"$lock"
        }

        cmd_get() {
            scope="$1"; key="$2"
            [ -z "$scope" ] || [ -z "$key" ] && { echo "usage: tado-config get <scope> <key>" >&2; exit 2; }
            path="$(scope_path "$scope")"
            [ -f "$path" ] || { echo "(no file at $path)"; exit 0; }
            python3 - "$path" "$key" <<'PYEOF'
        import json, sys
        with open(sys.argv[1]) as f:
            data = json.load(f)
        for part in sys.argv[2].split('.'):
            if isinstance(data, dict) and part in data:
                data = data[part]
            else:
                print(""); sys.exit(0)
        if isinstance(data, (dict, list)):
            print(json.dumps(data, indent=2))
        else:
            print(data)
        PYEOF
        }

        cmd_set() {
            scope="$1"; key="$2"; value="$3"
            [ -z "$scope" ] || [ -z "$key" ] && { echo "usage: tado-config set <scope> <key> <value>" >&2; exit 2; }
            path="$(scope_path "$scope")"
            mkdir -p "$(dirname "$path")"
            [ -f "$path" ] || echo '{}' > "$path"
            payload=$(python3 - "$path" "$key" "$value" <<'PYEOF'
        import json, sys, datetime
        path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
        with open(path) as f:
            data = json.load(f)
        # Parse value as JSON if possible (true/false/numbers/objects), else string.
        try:
            parsed = json.loads(value)
        except Exception:
            parsed = value
        cursor = data
        parts = key.split('.')
        for part in parts[:-1]:
            if not isinstance(cursor.get(part), dict):
                cursor[part] = {}
            cursor = cursor[part]
        cursor[parts[-1]] = parsed
        # Bump writer/updatedAt so other watchers can trace who wrote.
        data['writer'] = 'tado-config-cli'
        data['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
        print(json.dumps(data, indent=2, sort_keys=True))
        PYEOF
            )
            atomic_write "$path" "$payload"
            echo "set $scope.$key = $value"
        }

        cmd_list() {
            scope="${1:-global}"
            path="$(scope_path "$scope")"
            [ -f "$path" ] || { echo "(no file at $path)"; exit 0; }
            cat "$path"
        }

        cmd_path() {
            scope_path "${1:-global}"
        }

        cmd_export() {
            dest="${1:-}"
            [ -z "$dest" ] && { echo "usage: tado-config export <path-to-tarball>" >&2; exit 2; }
            root="$HOME/Library/Application Support/Tado"
            [ -d "$root" ] || { echo "no Tado store at $root" >&2; exit 2; }
            # Skip caches + prior backups to keep archive lean + non-recursive.
            tar -czf "$dest" \
                --exclude 'Tado/backups' \
                --exclude 'Tado/cache' \
                --exclude 'Tado/logs' \
                -C "$HOME/Library/Application Support" \
                "Tado"
            echo "wrote $dest"
        }

        cmd_import() {
            src="${1:-}"
            [ -z "$src" ] || [ ! -f "$src" ] && { echo "usage: tado-config import <path-to-tarball>" >&2; exit 2; }
            parent="$HOME/Library/Application Support"
            mkdir -p "$parent"
            # Archive's top-level entry is `Tado/` — extract into parent
            # and it lands in the right place.
            tar -xzf "$src" -C "$parent"
            echo "restored from $src"
            echo "note: relaunch Tado.app so SwiftData + watchers pick up the new tree."
        }

        case "${1:-}" in
            get)    shift; cmd_get    "$@" ;;
            set)    shift; cmd_set    "$@" ;;
            list)   shift; cmd_list   "$@" ;;
            path)   shift; cmd_path   "$@" ;;
            export) shift; cmd_export "$@" ;;
            import) shift; cmd_import "$@" ;;
            *)
                cat <<'HLP'
        tado-config — read + write Tado settings atomically.

        Usage:
          tado-config get    <scope> <dot.key>
          tado-config set    <scope> <dot.key> <value>
          tado-config list   [scope]
          tado-config path   [scope]
          tado-config export <tarball.tar.gz>
          tado-config import <tarball.tar.gz>

        Scopes: global | project (or project-shared) | local (or project-local)
        Values are JSON when parseable (true/false/1/2/"str"/{...}), otherwise raw strings.

        Examples:
          tado-config get global ui.bellMode
          tado-config set global ui.bellMode '"off"'
          tado-config set project eternal.mode '"sprint"'
          tado-config list project
          tado-config export /tmp/tado-backup.tar.gz
          tado-config import /tmp/tado-backup.tar.gz
        HLP
                ;;
        esac
        """#

        let url = binDir.appendingPathComponent("ext-tado-config")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - tado-notify

    private static func writeTadoNotify(to binDir: URL) {
        let script = #"""
        #!/bin/bash
        # Publishes a Tado event by appending a single NDJSON line to
        # ~/Library/Application Support/Tado/events/current.ndjson under
        # the same flock discipline as the Swift-side EventPersister.
        # Works whether or not Tado.app is running — the app picks up
        # events on next launch from the durable log.
        set -e

        EVENTS_FILE="$HOME/Library/Application Support/Tado/events/current.ndjson"

        usage() {
            cat <<'HLP'
        tado-notify — publish a user event to the Tado event log.

        Usage:
          tado-notify send "<title>" [--body "<body>"] [--severity info|success|warning|error]
          tado-notify tail [N]      # Print the last N events (default 20).

        Severity defaults to info.
        HLP
        }

        cmd_send() {
            title=""
            body=""
            severity="info"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --body)     body="$2"; shift 2 ;;
                    --severity) severity="$2"; shift 2 ;;
                    *)          if [ -z "$title" ]; then title="$1"; fi; shift ;;
                esac
            done
            [ -z "$title" ] && { usage; exit 2; }

            mkdir -p "$(dirname "$EVENTS_FILE")"
            line=$(python3 - "$title" "$body" "$severity" <<'PYEOF'
        import json, sys, uuid, datetime
        title, body, severity = sys.argv[1], sys.argv[2], sys.argv[3]
        event = {
            "id": str(uuid.uuid4()),
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
            "type": "user.broadcast",
            "severity": severity,
            "source": {"kind": "user"},
            "title": title,
            "body": body,
            "actions": [],
            "read": False,
        }
        print(json.dumps(event, separators=(',', ':')))
        PYEOF
            )

            lock="${EVENTS_FILE}.lock"
            (
                flock 9
                printf '%s\n' "$line" >> "$EVENTS_FILE"
            ) 9>"$lock"
            echo "published: $line"
        }

        cmd_tail() {
            n="${1:-20}"
            [ -f "$EVENTS_FILE" ] || { echo "(no events yet)"; exit 0; }
            tail -n "$n" "$EVENTS_FILE"
        }

        case "${1:-}" in
            send) shift; cmd_send "$@" ;;
            tail) shift; cmd_tail "$@" ;;
            *) usage ;;
        esac
        """#

        let url = binDir.appendingPathComponent("ext-tado-notify")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - tado-memory

    private static func writeTadoMemory(to binDir: URL) {
        let script = #"""
        #!/bin/bash
        # Tado memory CLI. Agent-facing read/write surface for the
        # user-global and project-scoped memory substrates.
        #   user.md     — ~/Library/Application Support/Tado/memory/user.md
        #   project.md  — <project>/.tado/memory/project.md
        #   notes/      — <project>/.tado/memory/notes/<ISO>-<slug>.md
        set -e

        USER_MD="$HOME/Library/Application Support/Tado/memory/user.md"

        find_project_root() {
            dir="$PWD"
            while [ "$dir" != "/" ]; do
                if [ -d "$dir/.tado" ]; then echo "$dir"; return; fi
                dir="$(dirname "$dir")"
            done
            return 1
        }

        scope_file() {
            case "$1" in
                user)    echo "$USER_MD" ;;
                project|"")
                    root="$(find_project_root)" || { echo "no .tado/ found above $PWD" >&2; exit 2; }
                    echo "$root/.tado/memory/project.md" ;;
                *) echo "unknown scope: $1" >&2; exit 2 ;;
            esac
        }

        ensure() {
            mkdir -p "$(dirname "$1")"
            [ -f "$1" ] || touch "$1"
        }

        usage() {
            cat <<'HLP'
        tado-memory — long-lived context shared across runs/agents.

        Usage:
          tado-memory read   [scope]                  # cat the file (default scope: project)
          tado-memory note   "<text>" [--scope project|user] [--tag a,b]
          tado-memory search <query> [--scope project|user|all]
          tado-memory path   [scope]

        Examples:
          tado-memory note "prefers pnpm over npm" --tag tooling
          tado-memory search "coverage"
          tado-memory read user
        HLP
        }

        cmd_read() {
            scope="${1:-project}"
            f="$(scope_file "$scope")"
            ensure "$f"
            cat "$f"
        }

        cmd_path() {
            scope_file "${1:-project}"
        }

        cmd_note() {
            text=""
            scope="project"
            tags=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --scope) scope="$2"; shift 2 ;;
                    --tag)   tags="$2"; shift 2 ;;
                    *)       if [ -z "$text" ]; then text="$1"; fi; shift ;;
                esac
            done
            [ -z "$text" ] && { usage; exit 2; }

            if [ "$scope" = "notes" ] || { [ "$scope" = "project" ] && [ -n "$tags" ]; }; then
                root="$(find_project_root)" || { echo "no .tado/ found above $PWD" >&2; exit 2; }
                dir="$root/.tado/memory/notes"
                mkdir -p "$dir"
                iso=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
                slug=$(echo "$text" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//' | cut -c1-40)
                [ -z "$slug" ] && slug="note"
                f="$dir/$iso-$slug.md"
                {
                    echo "---"
                    echo "timestamp: $iso"
                    [ -n "$tags" ] && echo "tags: [${tags}]"
                    echo "---"
                    echo
                    echo "$text"
                } > "$f"
                echo "wrote $f"
            else
                f="$(scope_file "$scope")"
                ensure "$f"
                lock="${f}.lock"
                iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                (
                    flock 9
                    {
                        echo
                        echo "## $iso"
                        [ -n "$tags" ] && echo "_tags: $tags_"
                        echo
                        echo "$text"
                    } >> "$f"
                ) 9>"$lock"
                echo "appended to $f"
            fi
        }

        cmd_search() {
            query=""
            scope="all"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --scope) scope="$2"; shift 2 ;;
                    *)       if [ -z "$query" ]; then query="$1"; fi; shift ;;
                esac
            done
            [ -z "$query" ] && { usage; exit 2; }

            case "$scope" in
                user)    files=("$USER_MD") ;;
                project) root="$(find_project_root)" || exit 0
                         files=("$root/.tado/memory/project.md")
                         # Also search notes/
                         [ -d "$root/.tado/memory/notes" ] && files+=( "$root/.tado/memory/notes"/*.md )
                         ;;
                all|*)   root="$(find_project_root)" || root=""
                         files=("$USER_MD")
                         if [ -n "$root" ]; then
                             files+=( "$root/.tado/memory/project.md" )
                             [ -d "$root/.tado/memory/notes" ] && files+=( "$root/.tado/memory/notes"/*.md )
                         fi
                         ;;
            esac

            for f in "${files[@]}"; do
                [ -f "$f" ] || continue
                if grep -in --color=always "$query" "$f" 2>/dev/null; then
                    echo "  (in $f)"
                fi
            done
        }

        case "${1:-}" in
            read)   shift; cmd_read   "$@" ;;
            path)   shift; cmd_path   "$@" ;;
            note)   shift; cmd_note   "$@" ;;
            search) shift; cmd_search "$@" ;;
            *) usage ;;
        esac
        """#

        let url = binDir.appendingPathComponent("ext-tado-memory")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Install helper

    private static func install(_ name: String, from srcDir: URL, to destDir: URL) {
        let src = srcDir.appendingPathComponent("ext-\(name)")
        let dest = destDir.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: src, to: dest)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }
}
