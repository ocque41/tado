// Relay Eternal landing surface per brief section 6.9.
//
// Lists every eternal run across every project. Click a row to
// open the existing EternalFileModal.

import SwiftUI
import SwiftData

struct RelayEternalView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Query(sort: \EternalRun.createdAt, order: .reverse) private var runs: [EternalRun]

    private var running: Int  { runs.filter { $0.state == "running" }.count }
    private var stopped: Int  { runs.filter { $0.state == "stopped" }.count }
    private var failed: Int   { runs.filter { $0.state == "failed" }.count }

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "AGENTS — ETERNAL",
                title: "Performance + sprint, on a schedule.",
                lead: "The Eternal step measures the SprintSuccessScore + perf composite over your project's `sprint_rules.txt`. Baselines ratchet on improvement. No watchdog, no auto-retry.",
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
                RelayKicker(text: "NO ETERNAL RUNS")
                Text("Open a project's Eternal section to start a run.")
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
            RelayStat("STOPPED", "\(stopped)"),
            RelayStat("FAILED",  "\(failed)"),
        ])
    }

    private var runsTable: some View {
        RelaySection(
            kicker: "ALL RUNS",
            title: "Newest first.",
            content: {
                VStack(spacing: 0) {
                    RelayTableHeader(columns: [
                        RelayTableColumn("RUN",      width: .fixed(96)),
                        RelayTableColumn("LABEL"),
                        RelayTableColumn("KIND",     alignment: .trailing, width: .fixed(96)),
                        RelayTableColumn("STATE",    alignment: .trailing, width: .fixed(140)),
                    ])
                    ForEach(runs) { run in
                        runRow(run: run)
                    }
                }
            }
        )
    }

    private func runRow(run: EternalRun) -> some View {
        RelayTableRow(content: {
            RelayTableCell(text: run.shortID, style: .meta, width: 96)
            RelayTableCell(text: run.label, style: .body)
            RelayTableCell(text: run.kind.uppercased(),
                           style: .meta, alignment: .trailing, width: 96)
            HStack {
                Spacer()
                RelayPill(label: run.state,
                          variant: run.state == "failed" ? .strike : .outline,
                          statusDot: run.state == "running" ? .running : (run.state == "stopped" ? .idle : nil))
            }
            .padding(.trailing, 12)
            .frame(width: 140)
        }, onClick: {
            appState.eternalModalRunID = run.id
        })
    }
}
