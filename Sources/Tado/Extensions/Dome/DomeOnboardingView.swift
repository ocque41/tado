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
            Palette.bgPage.opacity(0.94).ignoresSafeArea()
            content
                .padding(28)
                .frame(maxWidth: 580)
                .background(Palette.bgElev)
                .overlay(
                    Rectangle()
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
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
        VStack(alignment: .leading, spacing: 0) {
            // Header — overline + headline + body, hairline rule below.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    OverlineLabel("Onboarding · Embedding model")
                    Spacer()
                    if let status {
                        statusPillForState(status)
                    }
                }
                Text("Dome needs the embedding model")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Palette.ink)
                Text("Qwen3-Embedding-0.6B runs locally. Until it loads, search uses lexical matches.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 18)

            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)

            // Progress — primary action + total + linear bar + filename.
            progressSection
                .padding(.vertical, 18)

            if let error = status?.error ?? manualPathError {
                Text(error)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.danger)
                    .padding(.vertical, 4)
            }

            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)

            offlineSection
                .padding(.top, 18)
        }
    }

    /// Map the model-status into the structural design's StatusPill
    /// vocabulary. Ready → done; completed-but-not-ready → review;
    /// downloading → planning; idle → draft.
    @ViewBuilder
    private func statusPillForState(_ status: DomeRpcClient.ModelStatus) -> some View {
        if status.ready {
            StatusPill("ready", variant: .running)
        } else if status.completed {
            StatusPill("verifying", variant: .review)
        } else if status.totalBytes > 0 {
            StatusPill("downloading", variant: .planning)
        } else {
            StatusPill("idle", variant: .draft)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                primaryActionButton
                Spacer()
                if let status, status.totalBytes > 0 {
                    Text(progressLabel(for: status))
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                }
            }
            ProgressView(value: status?.fractionComplete ?? 0)
                .progressViewStyle(.linear)
                .tint(Palette.accent)
            if let current = status?.currentFile {
                Text("Downloading \(current)…")
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if status?.ready == true {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Ready")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Palette.green)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.greenSoft, lineWidth: DK.ruleW)
            )
        } else if status?.completed == true {
            OutlineButton(
                "Verify",
                icon: "arrow.clockwise",
                size: .regular,
                variant: .accent,
                action: { refresh() }
            )
        } else {
            OutlineButton(
                "Download model",
                icon: "arrow.down.circle.fill",
                size: .regular,
                variant: .accent,
                action: startFetch
            )
        }
    }

    @ViewBuilder
    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                OverlineLabel("Offline")
                Spacer()
                Text("ALREADY HAVE THE FILES?")
                    .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ink4)
            }
            Text("Choose a local model directory with config, tokenizer, and weights files.")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("/path/to/qwen3-embedding-0.6b", text: $manualPath)
                    .textFieldStyle(.plain)
                    .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.bgPage)
                    .overlay(
                        RoundedRectangle(cornerRadius: DK.radius)
                            .stroke(Palette.rule, lineWidth: DK.ruleW)
                    )
                OutlineButton("Choose…", size: .regular, variant: .standard, action: pickFolder)
                OutlineButton(
                    "Load",
                    size: .regular,
                    variant: .accent,
                    action: loadManual
                )
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
