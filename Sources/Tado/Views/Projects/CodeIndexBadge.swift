import SwiftUI

/// Small badge that mirrors the live code-index state for one project.
/// Shows three modes:
///
/// - **Indexing** — spinning indicator + "X / Y files".
/// - **Watching** — solid pulse + chunk count.
/// - **Idle** — hidden entirely (the absence of a badge is a signal
///   too; a healthy fully-indexed project shouldn't clutter the row).
///
/// Polls `DomeRpcClient.codeIndexStatus` + `codeWatchList` at 1.5 s
/// cadence. Cheap — both FFIs are local lock + atomic reads.
struct CodeIndexBadge: View {
    let projectID: String

    @State private var status: DomeRpcClient.CodeIndexStatus?
    @State private var watching = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let status, status.running {
                indexingBody(status: status)
            } else if watching {
                watchingBody
            } else {
                EmptyView()
            }
        }
        .onAppear {
            refresh()
            startPolling()
        }
        .onDisappear { stopPolling() }
        .onChange(of: projectID) { _, _ in refresh() }
    }

    @ViewBuilder
    private func indexingBody(status: DomeRpcClient.CodeIndexStatus) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("\(status.filesDone) / \(max(status.filesTotal, status.filesDone))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if status.chunksDone > 0 {
                Text("· \(status.chunksDone) chunks")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .help("Indexing project source. Hover to keep watching live.")
    }

    @ViewBuilder
    private var watchingBody: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.caption2)
                .foregroundStyle(.green)
            Text("watching")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("File watcher is live — code index updates on save.")
    }

    private func refresh() {
        status = DomeRpcClient.codeIndexStatus(projectID: projectID)
        watching = DomeRpcClient.codeWatchList().contains(projectID)
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
