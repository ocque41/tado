import Foundation

/// Detects whether a freshly-typed todo on the general todo page
/// is a coordinator brief or an ordinary spawn-a-tile request.
/// Pure function; no SwiftData / SwiftUI dependency. Unit-testable
/// in isolation.
///
/// The user-facing contract: typing `tado <anything>` (case
/// insensitive, optionally followed by a colon or newline) routes
/// to the coordinator. Anything else routes to the existing
/// spawn-a-todo path.
///
/// Examples that trigger the coordinator:
///   - `tado go to tado project and trigger eternal for auth`
///   - `Tado: bootstrap a2a docs for ledgermind`
///   - `TADO\nrun a sprint on persistence in foo`
///
/// Examples that do NOT trigger:
///   - `tado` (bare keyword with no brief)
///   - `tado-deploy something` (looks like a CLI invocation)
///   - `look up tado in the docs` (`tado` is not the leading word)
enum TodoCommand: Equatable {
    case standardPrompt(String)
    case coordinator(brief: String)

    static func detect(_ input: String) -> TodoCommand {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .standardPrompt(trimmed) }

        let lower = trimmed.lowercased()
        // Bare `tado` with no brief — fall through to standard.
        // The user might just be typing the word and pause; we
        // shouldn't kidnap their input.
        if lower == "tado" { return .standardPrompt(trimmed) }

        // Reject `tado-` prefixes (e.g. `tado-deploy`) — those
        // are CLI invocations the user wants to drop into a
        // shell, not a coordinator brief.
        if lower.hasPrefix("tado-") { return .standardPrompt(trimmed) }

        let prefixes = ["tado ", "tado:", "tado\n", "tado\t"]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            let brief = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
            return brief.isEmpty
                ? .standardPrompt(trimmed)
                : .coordinator(brief: brief)
        }

        return .standardPrompt(trimmed)
    }
}
