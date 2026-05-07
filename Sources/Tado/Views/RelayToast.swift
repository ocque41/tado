// Relay toast — bottom-center editorial card with the modal
// shadow, auto-dismiss after 2400ms per brief section 10.
//
// `RelayToastHost` is the app-level overlay that subscribes to
// the EventBus and presents toasts when an event with severity
// `.info` or `.warning` arrives. Hooked into ContentView's outer
// ZStack alongside the InAppBannerOverlay.

import SwiftUI

@MainActor
struct RelayToastHost: View {
    @Environment(\.relayTheme) private var theme
    @State private var current: Toast? = nil
    @State private var observer: NSObjectProtocol?

    private struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let isLive: Bool
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let toast = current {
                toastCard(toast)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .allowsHitTesting(false)
        .onAppear { installObserver() }
        .onDisappear { removeObserver() }
    }

    private func toastCard(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            if toast.isLive {
                Circle()
                    .fill(RelayPalette.terracotta)
                    .frame(width: 7, height: 7)
            }
            Text(toast.title.uppercased())
                .font(Typography.sans(size: 11, weight: .medium))
                .tracking(RelayTracking.caps(11))
                .foregroundStyle(RelayPalette.foreground(for: theme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .fill(RelayPalette.background(for: theme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .shadow(
            color: RelayShadow.modalColor,
            radius: RelayShadow.modalRadius,
            x: RelayShadow.modalX,
            y: RelayShadow.modalY
        )
    }

    private func installObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .relayToastRequest,
            object: nil,
            queue: .main
        ) { note in
            Task { @MainActor in
                guard let title = note.userInfo?["title"] as? String else { return }
                let live = (note.userInfo?["live"] as? Bool) ?? false
                let toast = Toast(title: title, isLive: live)
                withAnimation(.easeOut(duration: 0.2)) {
                    current = toast
                }
                try? await Task.sleep(nanoseconds: UInt64(RelayMotionTokens.durToast * 1_000_000_000))
                if current?.id == toast.id {
                    withAnimation(.easeIn(duration: 0.2)) {
                        current = nil
                    }
                }
            }
        }
    }

    private func removeObserver() {
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
        }
    }
}

extension Notification.Name {
    /// Post a `relayToastRequest` with `userInfo: ["title": "…",
    /// "live": Bool]` to surface a toast. The host listens app-wide.
    static let relayToastRequest = Notification.Name("relayToastRequest")
}
