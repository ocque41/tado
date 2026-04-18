import SwiftUI

/// The detail view's dispatch zone — the single most prominent block
/// on the page. Handles every dispatch lifecycle state with a distinct
/// visual:
///
/// - **idle** (no plan): a dashed-border placeholder nudging the user
///   to create a dispatch plan. Big primary CTA inside.
/// - **drafted / planning, no plan on disk**: "ARCHITECT PLANNING"
///   status with the brief preview + Edit. Architect is working on
///   the canvas; the user watches, doesn't press anything.
/// - **drafted / planning, plan on disk**: "READY · N phases" with
///   Edit (secondary) + Start (primary, accent-filled). The plan is
///   ready to launch.
/// - **dispatching**: "RUNNING · N phases" with Edit + Watch on
///   Canvas. Chain is live; the user goes to the canvas to watch.
///
/// Phase count is read live from `.tado/dispatch/phases/` via
/// `DispatchPlanService.phaseFileCount`.
struct ProjectDispatchSection: View {
    let project: Project
    let onNewDispatch: () -> Void
    let onEdit: () -> Void
    let onStart: () -> Void
    let onWatchOnCanvas: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISPATCH")
                .font(Typography.callout)
                .tracking(0.6)
                .foregroundStyle(Palette.textSecondary)

            cardBody
        }
    }

    // MARK: - Body by state

    @ViewBuilder
    private var cardBody: some View {
        switch currentState {
        case .idle:
            idleCard
        case .planning:
            planningCard
        case .ready:
            readyCard
        case .dispatching:
            dispatchingCard
        }
    }

    /// No plan yet. Invite the user to start one.
    private var idleCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("No dispatch plan yet")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                Text("Describe a multi-phase super-project. Tado's Dispatch Architect will design the plan and launch the phases on your canvas.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onNewDispatch) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Dispatch")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.surfaceAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    /// Architect is working on the plan. Brief preview + planning status.
    private var planningCard: some View {
        cardChrome(
            statusLabel: "ARCHITECT PLANNING",
            statusFg: Palette.accent,
            statusBg: Palette.accent.opacity(0.12),
            substate: "Watch the architect terminal on the canvas",
            leftBorderAccent: false
        ) {
            Button(action: onEdit) {
                Text("Edit")
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
    }

    /// Plan is on disk. Start is the primary CTA.
    private var readyCard: some View {
        cardChrome(
            statusLabel: "READY",
            statusFg: Palette.success,
            statusBg: Palette.success.opacity(0.15),
            substate: phaseCountLabel(suffix: "ready to launch"),
            leftBorderAccent: false
        ) {
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Text("Edit")
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

                Button(action: onStart) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Start")
                            .font(Typography.label)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Chain is live. Watch-on-canvas is the primary action.
    private var dispatchingCard: some View {
        cardChrome(
            statusLabel: "RUNNING",
            statusFg: Palette.accent,
            statusBg: Palette.accent.opacity(0.22),
            substate: phaseCountLabel(suffix: "dispatching"),
            leftBorderAccent: true
        ) {
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Text("Redo…")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Palette.warning.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button(action: onWatchOnCanvas) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .bold))
                        Text("Watch on Canvas")
                            .font(Typography.label)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shared card chrome

    /// Brief preview + status capsule top, action buttons bottom-right.
    /// Lifted into a helper because drafted/planning/ready/dispatching
    /// all share the same shape — only the status pill and the action
    /// buttons vary.
    private func cardChrome<Actions: View>(
        statusLabel: String,
        statusFg: Color,
        statusBg: Color,
        substate: String?,
        leftBorderAccent: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(briefPreview)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let substate {
                        Text(substate)
                            .font(Typography.monoCaption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }

                Spacer()

                Text(statusLabel)
                    .font(Typography.microBold)
                    .tracking(0.8)
                    .foregroundStyle(statusFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusBg)
                    .clipShape(Capsule())
                    .fixedSize()
            }

            HStack {
                Spacer()
                actions()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceElevated)
        .overlay(alignment: .leading) {
            if leftBorderAccent {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Derived values

    private enum CardState {
        case idle
        case planning
        case ready
        case dispatching
    }

    private var currentState: CardState {
        let state = project.dispatchState
        if state == "idle" || state.isEmpty {
            return .idle
        }
        if state == "dispatching" {
            return .dispatching
        }
        // drafted / planning branches on whether plan.json is written
        if DispatchPlanService.planExistsOnDisk(project) {
            return .ready
        }
        return .planning
    }

    /// First ~200 chars of the brief, first paragraph only, ellipsis if
    /// truncated. Gives the user a reminder of what they asked for
    /// without eating half the card.
    private var briefPreview: String {
        let md = project.dispatchMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if md.isEmpty {
            return "(no brief written yet)"
        }
        let firstParagraph = md.split(separator: "\n\n", maxSplits: 1).first.map(String.init) ?? md
        let limit = 200
        if firstParagraph.count <= limit {
            return firstParagraph
        }
        let clipped = firstParagraph.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped + "…"
    }

    private func phaseCountLabel(suffix: String) -> String {
        let n = DispatchPlanService.phaseFileCount(project)
        if n == 0 {
            return suffix
        }
        return "\(n) \(n == 1 ? "phase" : "phases") · \(suffix)"
    }
}
