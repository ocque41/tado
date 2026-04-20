import SwiftUI

/// Drill-down sheet for a single sprint row in `.tado/eternal/metrics.jsonl`.
///
/// Surfaces the proof that lives one filesystem hop away from the running
/// card: the composite score, its per-dimension breakdown, the milestone
/// tag, the architect's note, and an `Open in Finder` for `metrics.jsonl`.
/// Read-only — mutating the trial from the UI would open a sync-bug pit
/// (hook writes and UI writes could clobber each other).
///
/// Opened from the composite sparkline tap in `ProjectEternalSection`.
struct EternalSprintDetailSheet: View {
    let run: EternalRun
    let sprint: Int
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            bodyContent
            Divider()
            footerBar
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Palette.background)
    }

    // MARK: - Data access

    /// Re-reads metrics every time the sheet appears. The loop writes
    /// `metrics.jsonl` infrequently (once per sprint), so the read cost is
    /// negligible and keeps this sheet self-contained — no need to pass a
    /// `[EternalMetricSample]` binding down from the section.
    private var sample: EternalMetricSample? {
        EternalService.readMetrics(run).first { $0.sprint == sprint }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button(action: { dismiss(); onDismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                    Text("Close")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
            }

            Spacer()

            Text("")
                .font(Typography.label)
                .frame(width: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var footerBar: some View {
        HStack {
            Text("Source: .tado/eternal/metrics.jsonl · read-only")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            Spacer()

            Button(action: revealInFinder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Open in Finder")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Palette.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var title: String {
        if let s = sample, let composite = s.metric.numberValue {
            return String(format: "Sprint %d — composite %.3f", sprint, composite)
        }
        if let s = sample {
            return "Sprint \(sprint) — \(s.metric.display)"
        }
        return "Sprint \(sprint)"
    }

    // MARK: - Body content

    @ViewBuilder
    private var bodyContent: some View {
        if let sample {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metadataRow(sample: sample)
                    if let components = sample.components, !components.isEmpty {
                        dimensionsSection(components: components)
                    }
                    noteSection(note: sample.note)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.background)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.textTertiary)
                Text("Sprint \(sprint) not found in metrics.jsonl")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                Text("The row may not have been written yet, or the file was cleared.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadataRow(sample: EternalMetricSample) -> some View {
        HStack(spacing: 16) {
            metaTile(title: "SPRINT", value: "\(sample.sprint)")
            if let milestone = sample.milestone, !milestone.isEmpty {
                metaTile(title: "MILESTONE", value: milestone)
            }
            metaTile(title: "TIMESTAMP", value: sample.timestamp, mono: true)
        }
    }

    private func metaTile(title: String, value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(mono
                      ? .system(size: 12, weight: .medium, design: .monospaced)
                      : Typography.body)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func dimensionsSection(components: [String: Double]) -> some View {
        let ordered = Self.orderedKeys(from: Array(components.keys))
        return VStack(alignment: .leading, spacing: 10) {
            Text("DIMENSIONS")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            VStack(spacing: 6) {
                ForEach(ordered, id: \.self) { key in
                    dimensionBar(key: key, value: components[key] ?? 0)
                }
            }
            .padding(12)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func dimensionBar(key: String, value: Double) -> some View {
        let clamped = max(0, min(1, value))
        let tint: Color = value >= 0.9 ? Palette.success
                        : value >= 0.5 ? Palette.accent
                        : Palette.warning
        return HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 180, alignment: .leading)
            ProgressView(value: clamped)
                .tint(tint)
                .frame(maxWidth: .infinity)
            Text(Self.formatValue(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func noteSection(note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTE")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Text(note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                 ? note!
                 : "(no note recorded for this sprint)")
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.surfaceAccentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Actions

    private func revealInFinder() {
        let url = EternalService.metricsFileURL(run)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private static let preferredKeyOrder: [String] = [
        "build_clean", "build_smoke_pass", "scene_boots",
        "plan_validity", "plan_coverage", "chain_completion",
        "readme_truth", "no_placeholders",
        "token_efficiency", "phase_count_in_range",
        "milestone_progress", "polish_delta",
        "judge_verdict", "cost_efficiency",
    ]

    private static func orderedKeys(from keys: [String]) -> [String] {
        let set = Set(keys)
        var out = preferredKeyOrder.filter { set.contains($0) }
        out.append(contentsOf: set.subtracting(out).sorted())
        return out
    }

    private static func formatValue(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e6 {
            return String(Int(v))
        }
        if abs(v) >= 10 {
            return String(format: "%.3g", v)
        }
        return String(format: "%.2f", v)
    }
}
