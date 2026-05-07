// Relay Dispatch landing surface per brief section 6.7.
//
// Lists every dispatch run across every project (the per-project
// dispatch panes already exist inside ProjectDispatchSection).
// Click a row to open the existing DispatchFileModal.

import SwiftUI
import SwiftData

struct RelayDispatchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Query(sort: \DispatchRun.createdAt, order: .reverse) private var runs: [DispatchRun]

    private var running: Int    { runs.filter { $0.state == "dispatching" || $0.state == "running" }.count }
    private var queued: Int     { runs.filter { $0.state == "drafted" || $0.state == "ready" }.count }
    private var done: Int       { runs.filter { $0.state == "completed" }.count }

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "AGENTS — DISPATCH",
                title: runs.isEmpty
                    ? "No dispatch runs yet."
                    : "\(runs.count) dispatch \(runs.count == 1 ? "run" : "runs") · \(running) running.",
                lead: "The architect designs N phases, writes per-phase agents, and auto-chains execution. Phase agents wake the next via tado-deploy.",
                h1Size: 52
            )

            if runs.isEmpty {
                emptyState
            } else {
                statStrip
                runsTable
            }
        }
    }

    private var emptyState: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                RelayKicker(text: "NO DISPATCH RUNS")
                Text("Open a project and click Dispatch to architect a multi-phase plan.")
                    .font(RelayType.h2(size: 22))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                RelayInlineLink(label: "Open Projects", arrow: .forward) {
                    appState.currentView = .projects
                }
            }
        }
    }

    private var statStrip: some View {
        RelayStatStrip(stats: [
            RelayStat("RUNS",    "\(runs.count)"),
            RelayStat("RUNNING", "\(running)", meta: running > 0 ? "● Active" : nil, metaTint: running > 0 ? RelayPalette.terracotta : nil),
            RelayStat("QUEUED",  "\(queued)"),
            RelayStat("DONE",    "\(done)"),
        ])
    }

    private var runsTable: some View {
        RelaySection(
            kicker: "ALL RUNS",
            title: "Newest first.",
            content: {
                VStack(spacing: 0) {
                    RelayTableHeader(columns: [
                        RelayTableColumn("RUN",     width: .fixed(96)),
                        RelayTableColumn("LABEL"),
                        RelayTableColumn("PHASES",  alignment: .trailing, width: .fixed(96)),
                        RelayTableColumn("STATE",   alignment: .trailing, width: .fixed(140)),
                    ])
                    ForEach(runs) { run in
                        runRow(run: run)
                    }
                }
            }
        )
    }

    private func runRow(run: DispatchRun) -> some View {
        RelayTableRow(content: {
            RelayTableCell(text: run.shortID, style: .meta, width: 96)
            RelayTableCell(text: run.label, style: .body)
            RelayTableCell(text: "\(run.dispatchMode.uppercased())",
                           style: .meta, alignment: .trailing, width: 96)
            HStack {
                Spacer()
                RelayPill(label: run.state,
                          variant: run.state == "failed" ? .strike : .outline,
                          statusDot: run.state == "running" || run.state == "dispatching" ? .running : (run.state == "drafted" ? .idle : nil))
            }
            .padding(.trailing, 12)
            .frame(width: 140)
        }, onClick: {
            appState.dispatchModalRunID = run.id
        })
    }
}
