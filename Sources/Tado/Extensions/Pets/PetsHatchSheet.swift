import SwiftUI

/// Sheet UI presented when the user runs `/hatch <prompt>` or
/// clicks "Hatch new pet" in the Pets settings window.
///
/// What it does in v1
/// 1. Shows a prompt-prefilled textarea.
/// 2. On Generate, calls `PetsHatchService.requestHatch(prompt:)`,
///    which today writes a stub PNG into
///    `<storage-root>/pets/custom/`.
/// 3. Shows a "v1.1 lights up real generation" banner so the
///    user knows the result is a placeholder.
///
/// What lights up in v1.1
/// The same `PetsHatchService` registers a real
/// `PetsHatchGenerator` on first run. The sheet UI does not
/// change.
struct PetsHatchSheet: View {
    let request: PetsHatchRequest
    let onCompleted: (URL) -> Void
    let onDismiss: () -> Void

    @State private var prompt: String
    @State private var isGenerating: Bool = false
    @State private var lastErrorMessage: String?
    @State private var lastResultURL: URL?

    init(
        request: PetsHatchRequest,
        onCompleted: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.request = request
        self.onCompleted = onCompleted
        self.onDismiss = onDismiss
        _prompt = State(initialValue: request.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hatch a new pet")
                    .font(.system(size: 14, weight: .semibold))
                Text("Describe the pet — animal, vibe, colour, anything.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 140)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .disabled(isGenerating)

            v1StubBanner

            if let error = lastErrorMessage {
                Text("Hatch failed: \(error)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if let url = lastResultURL {
                Text("Saved to \(url.lastPathComponent). Open Pet settings to pick it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.85))
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isGenerating ? "Generating…" : "Generate") {
                    Task { await generate() }
                }
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var v1StubBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("v1 placeholder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("Real image generation lights up in v1.1. For now, Generate writes a placeholder sprite tagged \u{201C}v1 stub\u{201D} so you can confirm the round-trip works.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.yellow.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 0.5)
        )
    }

    @MainActor
    private func generate() async {
        isGenerating = true
        lastErrorMessage = nil
        lastResultURL = nil
        do {
            let url = try await PetsHatchService.shared.requestHatch(prompt: prompt)
            lastResultURL = url
            onCompleted(url)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        isGenerating = false
    }
}
