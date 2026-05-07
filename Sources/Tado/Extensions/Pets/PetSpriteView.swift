import SwiftUI
import AppKit

/// SwiftUI view that renders one animated pet sprite + an
/// optional thought-bubble caption above it. Hosted inside the
/// floating `NSPanel` (`PetsFloatingPanelController`).
///
/// Animation strategy
/// - Frames come from `PetSpriteCache` keyed by `(petID, state)`.
/// - A SwiftUI `Timer.publish` ticks at the *current* frame's
///   declared duration; on each tick we advance to the next
///   frame and rebuild the timer with the new duration. APNGs
///   commonly use variable per-frame durations and a fixed-rate
///   timer drops or doubles frames.
/// - A `.transition(.opacity)` cross-fade hides decode hits when
///   the `state` flips between sprites.
///
/// Interactions
/// - **Tap** on the sprite → calls `onTap()` (the panel
///   controller wires this to opening the expanded popover).
/// - **Drag** anywhere in the sprite → calls `onDrag(delta:)` so
///   the panel can move with the user's gesture.
/// - **Hover** → small scale lift + shadow so the user sees the
///   sprite is interactive.
struct PetSpriteView: View {
    let petID: String
    let state: PetState
    let bubble: String?
    let badgeCount: Int
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    @State private var frames: [PetSpriteFrame] = []
    @State private var frameIndex: Int = 0
    @State private var timer: Timer?
    @State private var hovering: Bool = false
    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bubble, !bubble.isEmpty {
                ThoughtBubble(text: bubble)
                    .transition(.opacity)
            }

            ZStack(alignment: .topTrailing) {
                spriteImage
                    .resizable()
                    .interpolation(.none)        // pixel-art look
                    .frame(width: 96, height: 96)
                    .scaleEffect(hovering ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(0.45), radius: hovering ? 6 : 3, y: 2)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .contentShape(Circle())
                    // Double tap must be installed BEFORE single
                    // tap so SwiftUI's gesture-resolver gives it
                    // priority. With this order: 1 click → onTap;
                    // 2 clicks → onDoubleTap (popover suppressed).
                    .onTapGesture(count: 2) { onDoubleTap() }
                    .onTapGesture { onTap() }
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { gesture in
                                let delta = CGSize(
                                    width:  gesture.translation.width  - lastDragTranslation.width,
                                    height: gesture.translation.height - lastDragTranslation.height
                                )
                                lastDragTranslation = gesture.translation
                                onDrag(delta)
                            }
                            .onEnded { _ in
                                lastDragTranslation = .zero
                                onDragEnd()
                            }
                    )

                if badgeCount > 0 {
                    Text(badgeCount > 9 ? "9+" : String(badgeCount))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.red.opacity(0.92))
                        )
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("\(badgeCount) sessions awaiting input")
                }
            }
        }
        .padding(8)
        .onAppear { reload() }
        .onChange(of: petID) { _, _ in reload() }
        .onChange(of: state) { _, _ in reload() }
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - Frame playback

    private func reload() {
        frames = PetSpriteCache.shared.frames(petID: petID, state: state)
        frameIndex = 0
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        timer?.invalidate()
        guard frames.count > 1 else { return }    // static fallback → no timer
        let duration = frames[frameIndex].duration
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        scheduleNextTick()
    }

    private var spriteImage: Image {
        let nsImage: NSImage
        if frames.indices.contains(frameIndex) {
            nsImage = frames[frameIndex].image
        } else if let first = frames.first {
            nsImage = first.image
        } else {
            // PetSpriteCache should never return [] (it falls back
            // to a one-frame placeholder), but guard anyway so the
            // view is total.
            nsImage = NSImage(size: NSSize(width: 96, height: 96))
        }
        return Image(nsImage: nsImage)
    }
}

/// The thought-bubble caption rendered above the sprite. Plain
/// rounded-rect with a small tail; max 28 characters so it
/// never grows wider than the sprite.
private struct ThoughtBubble: View {
    let text: String

    var body: some View {
        Text(displayText)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }

    private var displayText: String {
        let max = 36
        if text.count <= max { return text }
        return text.prefix(max - 1) + "…"
    }
}
