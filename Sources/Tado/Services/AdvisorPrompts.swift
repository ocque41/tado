import Foundation
import CoreGraphics
import SwiftData

enum AdvisorPrompts {
    static func executionerPrompt(task: String) -> String {
        """
        You are the executioner in Tado Advisor mode.

        User task:
        \(task)

        Rules:
        - Do not plan the whole task.
        - Do not start until the advisor sends a step.
        - Execute exactly one advisor step at a time.
        - Keep replies short: result, key output, next blocker if any.
        - If a command is requested, run it and report the important output.
        - Do not ask the user unless the advisor tells you to.

        Reply with: READY
        """
    }

    static func advisorPrompt(
        task: String,
        executionerSessionID: UUID,
        executionerGridLabel: String
    ) -> String {
        let target = executionerSessionID.uuidString.lowercased()
        return """
        You are the advisor in Tado Advisor mode.

        User task:
        \(task)

        Executioner:
        - UUID: \(target)
        - Grid: \(executionerGridLabel)

        Workflow:
        - You decide the plan.
        - The executioner does the work.
        - Send one tiny step at a time.
        - Prefer messages under 240 characters.
        - Wait for executioner output before the next step.
        - Use `tado_send` / `tado_read` MCP tools if available.
        - Otherwise use `tado-send \(target) "<step>"` and `tado-read \(target) --tail 80`.
        - Do not edit files, run tests, or execute project commands yourself.
        - If relay output is clipped, ask with `tado-read \(target) --tail 160`.

        First step: tell the executioner the smallest useful action.
        """
    }
}

enum AdvisorRelay {
    static let maxRelayChars = 2_800
    static let maxRelayLines = 80

    @MainActor
    static func relayMessage(for session: TerminalSession, status: SessionStatus) -> String {
        let output = currentOutput(from: session)
        let compact = compactTail(output, maxChars: maxRelayChars, maxLines: maxRelayLines)
        let body = compact.isEmpty ? "(no visible output)" : compact
        return """
        [advisor-relay]
        executioner: \(session.title)
        status: \(status.rawValue)
        output:
        \(body)
        """
    }

    static func compactTail(
        _ text: String,
        maxChars: Int = maxRelayChars,
        maxLines: Int = maxRelayLines
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
            lines.insert("[clipped earlier lines]", at: 0)
        }

        var out = lines.joined(separator: "\n")
        if out.count > maxChars {
            let suffix = out.suffix(maxChars)
            out = "[clipped earlier output]\n" + suffix
        }
        return out
    }

    @MainActor
    private static func currentOutput(from session: TerminalSession) -> String {
        guard let core = session.coreSession else { return "" }
        var lines: [String] = []
        if let scrollback = core.scrollbackSnapshot(offset: 0, rows: 80) {
            lines.append(contentsOf: cellLines(cols: scrollback.cols, cells: scrollback.cells))
        }
        if let live = core.snapshotFull() {
            lines.append(contentsOf: cellLines(cols: live.cols, cells: live.cells))
        }
        return lines.joined(separator: "\n")
    }

    private static func cellLines(cols: UInt16, cells: [TadoCore.Cell]) -> [String] {
        guard cols > 0 else { return [] }
        return cells.chunks(of: Int(cols)).map { row in
            var line = ""
            line.reserveCapacity(row.count)
            for cell in row {
                if cell.ch == 0 {
                    line.append(" ")
                } else if let scalar = Unicode.Scalar(cell.ch) {
                    line.unicodeScalars.append(scalar)
                } else {
                    line.append(" ")
                }
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
    }
}

@MainActor
enum AdvisorTodoSpawner {
    static func nextAvailableGridIndex(
        usedIndices: [Int],
        reserving reserved: [Int] = []
    ) -> Int {
        let used = Set(usedIndices).union(reserved)
        var index = 0
        while used.contains(index) { index += 1 }
        return index
    }

    @discardableResult
    static func spawnNormalTodo(
        todo: TodoItem,
        task: String,
        settings: AppSettings,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        defaultEngine: TerminalEngine,
        advisorGridIndex: Int,
        advisorPosition: CGPoint,
        cwd: String?,
        projectName: String?,
        teamName: String? = nil,
        teamID: UUID? = nil,
        teamAgents: [String]? = nil,
        agentName: String? = nil,
        agentEngine: TerminalEngine? = nil
    ) -> (executioner: TerminalSession, advisor: TerminalSession?) {
        guard settings.advisorEnabled else {
            let session = terminalManager.spawnAndWire(
                todo: todo,
                engine: defaultEngine,
                cwd: cwd,
                agentName: agentName,
                projectName: projectName,
                teamName: teamName,
                teamID: teamID,
                teamAgents: teamAgents
            )
            return (session, nil)
        }
        settings.initializeAdvisorDefaultsIfNeeded()
        try? modelContext.save()

        let executionerEngine = settings.advisorEngine(for: .executioner)
        let advisorEngine = settings.advisorEngine(for: .advisor)
        let compatibleAgent = agentName.flatMap { name -> String? in
            if agentEngine == nil || agentEngine == executionerEngine {
                return name
            }
            return nil
        }

        let executioner = terminalManager.spawnAndWire(
            todo: todo,
            engine: executionerEngine,
            cwd: cwd,
            agentName: compatibleAgent,
            projectName: projectName,
            teamName: teamName,
            teamID: teamID,
            teamAgents: teamAgents,
            modeFlagsOverride: settings.advisorModeFlags(for: .executioner),
            modelFlagsOverride: settings.advisorModelFlags(for: .executioner),
            effortFlagsOverride: settings.advisorEffortFlags(for: .executioner),
            spawnPromptOverride: AdvisorPrompts.executionerPrompt(task: task),
            runRole: "executioner"
        )

        let advisorTodo = TodoItem(
            text: "Advisor: \(task)",
            gridIndex: advisorGridIndex,
            canvasPosition: advisorPosition
        )
        advisorTodo.projectID = todo.projectID
        advisorTodo.teamID = teamID
        advisorTodo.name = "Advisor"
        advisorTodo.kanbanColumnKey = todo.kanbanColumnKey
        modelContext.insert(advisorTodo)

        let advisor = terminalManager.spawnAndWire(
            todo: advisorTodo,
            engine: advisorEngine,
            cwd: cwd,
            projectName: projectName,
            teamName: teamName,
            teamID: teamID,
            teamAgents: teamAgents,
            modeFlagsOverride: settings.advisorModeFlags(for: .advisor),
            modelFlagsOverride: settings.advisorModelFlags(for: .advisor),
            effortFlagsOverride: settings.advisorEffortFlags(for: .advisor),
            spawnPromptOverride: AdvisorPrompts.advisorPrompt(
                task: task,
                executionerSessionID: executioner.id,
                executionerGridLabel: CanvasLayout.gridLabel(
                    forIndex: todo.gridIndex,
                    gridColumns: settings.gridColumns
                )
            ),
            runRole: "advisor"
        )
        terminalManager.linkAdvisor(executionerID: executioner.id, advisorID: advisor.id)
        return (executioner, advisor)
    }
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}
