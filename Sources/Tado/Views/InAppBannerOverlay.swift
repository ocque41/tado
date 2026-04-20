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

    /// How long each banner stays up before auto-fading.
    private let dismissAfter: TimeInterval = 5.0

    /// Max stack depth — above this, the oldest visible banner is
    /// evicted. Keeps the overlay out of the way in event storms.
    private let stackLimit = 3

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(eventsToShow) { event in
                BannerCard(event: event, onDismiss: { dismiss(event.id) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
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
        let task = Task { [dismissAfter] in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
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
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(severityColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
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
