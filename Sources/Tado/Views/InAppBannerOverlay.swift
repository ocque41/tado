import SwiftUI

/// Transient top-right overlay that surfaces the most recent unread
/// event when its routing includes `"inApp"`. Stacks up to
/// `stackLimit` banners, newest on top. Each auto-dismisses after
/// `dismissAfter` seconds; click-to-dismiss works anytime.
///
/// Observes `EventBus.shared.recent` directly — SwiftUI redraws
/// automatically via `@Observable`. The overlay maintains its own
/// "visible" ring separate from EventBus so a banner that was
/// auto-dismissed doesn't come back just because the user is still
/// scrolling the event log.
struct InAppBannerOverlay: View {
    @State private var visibleIDs: [UUID] = []
    @State private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    /// Default fade-out for `.warning` / `.error` events — slightly
    /// longer because the user usually wants a moment to read.
    private let dismissAfter: TimeInterval = 3.5

    /// Faster fade for `.info` / `.success` — these are
    /// acknowledgements, not asks, and should not linger.
    private let dismissAfterQuiet: TimeInterval = 2.0

    /// Max stack depth — above this, the oldest visible banner is
    /// evicted. Two is enough to show both the latest event and one
    /// piece of context without dominating the canvas.
    private let stackLimit = 2

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            ForEach(eventsToShow) { event in
                BannerCard(event: event, onDismiss: { dismiss(event.id) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!visibleIDs.isEmpty)
        .onChange(of: EventBus.shared.recent.last?.id) { _, _ in
            considerNewest()
        }
    }

    // MARK: - State

    private var eventsToShow: [TadoEvent] {
        let byID = Dictionary(uniqueKeysWithValues: EventBus.shared.recent.map { ($0.id, $0) })
        return visibleIDs.compactMap { byID[$0] }
    }

    private func considerNewest() {
        guard let latest = EventBus.shared.recent.last else { return }
        // Only surface if routed to inApp and the global channel is on.
        let settings = ScopedConfig.shared.get()
        guard settings.notifications.channels.inApp else { return }
        let channels = settings.notifications.eventRouting[latest.type] ?? []
        guard channels.contains("inApp") else { return }
        // De-dup: already showing this one.
        guard !visibleIDs.contains(latest.id) else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            visibleIDs.append(latest.id)
            while visibleIDs.count > stackLimit {
                let evicted = visibleIDs.removeFirst()
                dismissTasks[evicted]?.cancel()
                dismissTasks.removeValue(forKey: evicted)
            }
        }

        let id = latest.id
        let timeout: TimeInterval
        switch latest.severity {
        case .warning, .error:
            timeout = dismissAfter
        case .info, .success:
            timeout = dismissAfterQuiet
        }
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run { dismiss(id) }
            }
        }
        dismissTasks[id] = task
    }

    private func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            visibleIDs.removeAll { $0 == id }
        }
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
        EventBus.shared.markRead(id)
    }
}

// MARK: - Banner card

private struct BannerCard: View {
    let event: TadoEvent
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(severityColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Palette.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    private var severityColor: Color {
        switch event.severity {
        case .info:    return Palette.accent
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error:   return Palette.danger
        }
    }
}
