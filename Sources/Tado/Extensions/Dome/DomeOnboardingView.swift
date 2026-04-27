import SwiftUI

/// First-launch panel for the Qwen3-Embedding-0.6B model.
///
/// Why this view exists
/// --------------------
/// Until the model files (`config.json`, `tokenizer.json`,
/// `model.safetensors` ≈ 1.2 GB F16) are present in
/// `<vault>/.bt/models/qwen3-embedding-0.6b/`, Dome's `Qwen3EmbeddingProvider`
/// transparently falls back to a deterministic FNV-1a hash. The fallback
/// keeps the rest of the app running but produces non-semantic vectors —
/// "cat" and "feline" hash to unrelated rows. This view exposes the
/// download to the user, blocks `Qwen3`-dependent operations until the
/// model is loaded, and gives operators behind a corporate proxy the
/// "I have the file" escape hatch that points
/// `TADO_DOME_EMBEDDING_MODEL_PATH` at a manually-supplied directory.
///
/// Lifecycle
/// ---------
/// `tado_dome_start` already auto-loads the runtime when files are
/// present. So on a happy second launch this view never appears: the
/// status FFI returns `ready: true` immediately and `DomeRootView`
/// skips the overlay. On a cold first launch the user sees the
/// progress bar; on completion the runtime auto-attaches and
/// `ready` flips true on the next status poll.
struct DomeOnboardingView: View {
    /// 250 ms is fast enough that the bar feels live while keeping the
    /// status FFI cost negligible (it's a JSON marshal, no IO).
    private let pollInterval: TimeInterval = 0.25

    @State private var status: DomeRpcClient.ModelStatus?
    @State private var pollTimer: Timer?
    @State private var manualPath: String = ""
    @State private var manualPathError: String?
    @State private var isPickingFolder = false

    var body: some View {
        ZStack {
            Palette.background.opacity(0.92).ignoresSafeArea()
            content
                .padding(28)
                .frame(maxWidth: 540)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Palette.divider, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            refresh()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dome needs the embedding model")
                    .font(.title2.weight(.semibold))
                Text("Qwen3-Embedding-0.6B (~1.2 GB, F16) runs locally on your Mac. It's downloaded once and cached under your Dome vault. Until it's loaded, search returns lexical matches only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            progressSection

            if let error = status?.error ?? manualPathError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.red)
                    .padding(.vertical, 4)
            }

            Divider().overlay(Palette.divider)

            offlineSection
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                primaryActionButton
                Spacer()
                if let status, status.totalBytes > 0 {
                    Text(progressLabel(for: status))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: status?.fractionComplete ?? 0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            if let current = status?.currentFile {
                Text("Downloading \(current)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if status?.ready == true {
            Label("Ready", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else if status?.completed == true {
            Button("Verify") {
                refresh()
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: startFetch) {
                Label("Download model", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Already have the files?")
                .font(.callout.weight(.medium))
            Text("Point Dome at any directory containing config.json, tokenizer.json, and model.safetensors. The path is persisted as TADO_DOME_EMBEDDING_MODEL_PATH for the rest of this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("/path/to/qwen3-embedding-0.6b", text: $manualPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    pickFolder()
                }
                Button("Load") {
                    loadManual()
                }
                .disabled(manualPath.isEmpty)
            }
        }
    }

    private func progressLabel(for status: DomeRpcClient.ModelStatus) -> String {
        let mb = Double(status.downloadedBytes) / 1_048_576
        let totalMb = Double(status.totalBytes) / 1_048_576
        return String(format: "%.0f / %.0f MB", mb, totalMb)
    }

    private func refresh() {
        status = DomeRpcClient.modelStatus()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startFetch() {
        manualPathError = nil
        if !DomeRpcClient.startModelFetch() {
            manualPathError = "Couldn't start the download — Dome daemon isn't running yet."
        }
        refresh()
    }

    private func loadManual() {
        let trimmed = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if DomeRpcClient.setModelPath(trimmed) {
            manualPathError = nil
            refresh()
        } else {
            manualPathError = "That folder doesn't contain all three files. Need config.json, tokenizer.json, and model.safetensors."
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Qwen3-Embedding-0.6B folder"
        if panel.runModal() == .OK, let url = panel.url {
            manualPath = url.path
            loadManual()
        }
    }
}
