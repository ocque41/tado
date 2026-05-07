import Foundation

/// Live capability probe for the user's installed `claude` and `codex`
/// CLIs.
///
/// Tado spawns CLI processes with flags assembled from picker enums in
/// `AppState.swift`. Those enums are baked at app build time, so when a
/// CLI ships an enum-narrowing change (Claude Code removed `--effort`'s
/// `xhigh` value, Codex renamed `--ask-for-approval`'s `on-failure` to
/// deprecated, etc.) the picker can outlive the CLI's contract by weeks
/// before users notice. The result is the bug pattern this file
/// addresses: a tile spawns, the CLI rejects an unknown enum value with
/// `error: option ...`, and the agent dies in milliseconds.
///
/// The cache shells out to `<cli> --help` once per CLI per app launch
/// (or on demand after a user action), parses the documented enum
/// values from the help text, and exposes them to
/// `ProcessSpawner.sanitizeFlags` so we can drop unknown values BEFORE
/// they reach the CLI.
///
/// Stays purely additive: if `--help` parsing fails or the CLI isn't
/// installed, the cache returns `nil` for every `validValues(...)`
/// query and the sanitizer falls through to its existing `"auto"`-only
/// guard. We never reject a flag because the cache is empty — only
/// when the CLI explicitly told us it wouldn't accept it.
@MainActor
final class CLICapabilities {
    static let shared = CLICapabilities()

    /// Documented enum values keyed by `(engine, flag)`. `nil` means
    /// "we couldn't determine the set" — sanitizer treats this as
    /// "don't drop" so we never reject a flag we're uncertain about.
    private var enumValues: [String: Set<String>] = [:]
    private var probedEngines: Set<TerminalEngine> = []

    private init() {}

    /// Refresh the cache for `engine`. Idempotent — safe to call
    /// repeatedly. Runs `<cli> --help` synchronously off the main
    /// thread; the help text is small (<10 KB) and the parse is
    /// linear, so a single probe completes in <30 ms even on cold I/O.
    func probe(_ engine: TerminalEngine) {
        guard !probedEngines.contains(engine) else { return }
        probedEngines.insert(engine)
        let help = runHelp(engine: engine) ?? ""
        guard !help.isEmpty else { return }
        ingestHelpText(help, engine: engine)
    }

    /// Force a re-probe (e.g. after the user upgrades the CLI).
    /// Currently unused but exposed for future "Reload CLI capabilities"
    /// settings affordances.
    func invalidate() {
        enumValues.removeAll()
        probedEngines.removeAll()
    }

    /// `nil` means "unknown — don't filter."  An empty set means "we
    /// probed and the flag has no enum-restricted values" (rare —
    /// effectively the same as nil for sanitization purposes). A
    /// non-empty set means the flag is enum-restricted to those values.
    func validValues(engine: TerminalEngine, flag: String) -> Set<String>? {
        return enumValues[cacheKey(engine: engine, flag: flag)]
    }

    /// Shape-tolerant predicate used by `ProcessSpawner.sanitizeFlags`.
    /// Returns `true` when we have evidence the value would be rejected
    /// by the CLI; `false` when we don't know or know it's accepted.
    func shouldRejectValue(engine: TerminalEngine, flag: String, value: String) -> Bool {
        guard let valid = validValues(engine: engine, flag: flag) else {
            return false
        }
        if valid.isEmpty { return false }
        return !valid.contains(value)
    }

    // MARK: - Internal

    private func cacheKey(engine: TerminalEngine, flag: String) -> String {
        "\(engine.rawValue)::\(flag)"
    }

    private func runHelp(engine: TerminalEngine) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "\(engine.rawValue) --help 2>&1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Parse the `--help` output for enum-restricted flag values.
    /// Recognizes both shapes the user's installed CLIs emit:
    ///
    ///   --permission-mode <mode>   Permission mode... (choices: "acceptEdits", "auto", ...)
    ///   --effort <level>           Effort level... (low, medium, high, xhigh, max)
    ///   -a, --ask-for-approval <APPROVAL_POLICY>
    ///       Possible values:
    ///       - untrusted:  Only run...
    ///       - on-failure: DEPRECATED...
    ///
    /// Conservative on purpose: anything that doesn't match these
    /// shapes is left out of the cache (sanitizer then doesn't filter
    /// it). Better to miss a filtering opportunity than to drop a flag
    /// that's actually valid.
    func ingestHelpText(_ text: String, engine: TerminalEngine) {
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Shape 1 (Claude): single-line `(choices: "a", "b", "c")`
            // or paren-list `(low, medium, high)`.
            if let flag = extractFlagName(line),
               let values = extractInlineEnumValues(from: line) {
                enumValues[cacheKey(engine: engine, flag: flag)] = values
            }
            // Shape 2 (Codex): `Possible values:` block follows the flag
            // line a few lines down.
            if let flag = extractFlagName(line) {
                let scanWindow = min(lines.count, i + 12)
                var j = i + 1
                while j < scanWindow {
                    let probe = lines[j].trimmingCharacters(in: .whitespaces)
                    if probe.lowercased().hasPrefix("possible values:") {
                        // Some Codex flags inline the list:
                        //   [possible values: read-only, workspace-write, ...]
                        if let values = extractInlineCodexPossibleValues(from: lines[j]) {
                            enumValues[cacheKey(engine: engine, flag: flag)] = values
                            break
                        }
                        // Otherwise the list comes as `- value:  description`
                        // bullets in the next ~20 lines.
                        var bullets: Set<String> = []
                        var k = j + 1
                        let bulletWindow = min(lines.count, j + 24)
                        while k < bulletWindow {
                            let bulletLine = lines[k].trimmingCharacters(in: .whitespaces)
                            if bulletLine.hasPrefix("- "),
                               let colon = bulletLine.firstIndex(of: ":") {
                                let value = String(bulletLine[bulletLine.index(bulletLine.startIndex, offsetBy: 2)..<colon])
                                bullets.insert(value.trimmingCharacters(in: .whitespaces))
                            } else if !bulletLine.isEmpty, !bulletLine.hasPrefix("-") {
                                break
                            }
                            k += 1
                        }
                        if !bullets.isEmpty {
                            enumValues[cacheKey(engine: engine, flag: flag)] = bullets
                        }
                        break
                    }
                    if probe.hasPrefix("--") || probe.hasPrefix("-") && probe.count > 1 && probe[probe.index(after: probe.startIndex)].isLetter {
                        break
                    }
                    j += 1
                }
            }
            i += 1
        }
    }

    private func extractFlagName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("--") || trimmed.hasPrefix("-") else { return nil }
        // Pull the long form `--name` out of the line. Some lines start
        // with `-x, --name`; we always want the long form.
        var token = ""
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
            if word.hasPrefix("--") {
                token = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ","))
                break
            }
        }
        guard !token.isEmpty else { return nil }
        // Strip a trailing `<...>` placeholder if the long form ran into
        // it without a space (rare but observed in some help renderers).
        if let bracket = token.firstIndex(of: "<") {
            token = String(token[token.startIndex..<bracket])
        }
        return token
    }

    /// Match `(choices: "a", "b", "c")` or `(low, medium, high)`.
    private func extractInlineEnumValues(from line: String) -> Set<String>? {
        guard let openIdx = line.firstIndex(of: "("),
              let closeIdx = line[openIdx...].firstIndex(of: ")") else {
            return nil
        }
        let inside = line[line.index(after: openIdx)..<closeIdx]
        let body: Substring
        if let colonRange = inside.range(of: "choices:") {
            body = inside[colonRange.upperBound...]
        } else {
            body = inside[inside.startIndex...]
        }
        // Reject obvious non-enum parens like `(default: 5)` or
        // `(see https://...)`.
        if body.contains("http") || body.contains("default:") {
            return nil
        }
        var values: Set<String> = []
        for raw in body.split(separator: ",") {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !cleaned.isEmpty, !cleaned.contains(" ") {
                values.insert(cleaned)
            }
        }
        // Demand at least 2 values to consider it a true enum — single
        // entries inside parens are usually descriptive, not enum-like.
        return values.count >= 2 ? values : nil
    }

    /// Match Codex's inline `[possible values: a, b, c]` shape.
    private func extractInlineCodexPossibleValues(from line: String) -> Set<String>? {
        let lower = line.lowercased()
        guard let range = lower.range(of: "possible values:") else { return nil }
        let after = line[range.upperBound...]
        // Trim a trailing `]` if present.
        var body = after
        if let closeIdx = body.firstIndex(of: "]") {
            body = body[body.startIndex..<closeIdx]
        }
        var values: Set<String> = []
        for raw in body.split(separator: ",") {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !cleaned.contains(" ") {
                values.insert(cleaned)
            }
        }
        return values.isEmpty ? nil : values
    }
}
