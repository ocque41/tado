import Foundation
import AppKit
import SwiftUI

/// Owns the floating `NSPanel` that hosts the pet sprite. Lives
/// as long as `PetsCoordinator.shared` does — there's only ever
/// one panel.
///
/// Why an `NSPanel` and not a SwiftUI `WindowGroup`
/// SwiftUI's `WindowGroup` doesn't expose the level / collection
/// behaviour controls we need: `.canJoinAllSpaces` (so the pet
/// follows the user across macOS Spaces) and `.stationary` (so
/// Mission Control doesn't drag it). An `NSPanel` is the
/// AppKit-blessed primitive for menubar-style floating UI.
///
/// Behaviour
/// - **All Spaces** — `.canJoinAllSpaces` makes the panel
///   visible on every macOS Space.
/// - **Above all apps** — `.floating` window level. Above
///   normal windows, below alerts.
/// - **Non-activating** — `.nonactivatingPanel` style mask
///   means clicking the pet doesn't yank focus from whatever
///   the user is doing.
/// - **Borderless + transparent** — only the pet sprite is
///   visible; the panel chrome is invisible.
/// - **Drag to move** — `PetSpriteView`'s drag gesture calls
///   back into the controller so the panel position tracks
///   the cursor 1:1, then persists on drag-end.
/// - **Click to expand** — the same view's tap gesture opens
///   the `NSPopover` anchored to the sprite.
@MainActor
final class PetsFloatingPanelController: NSObject {
    private weak var coordinator: PetsCoordinator?
    private var panel: NSPanel?
    private var hosting: NSHostingController<PetsFloatingPanelRoot>?
    private let popover = NSPopover()
    private var saveDebounce: Task<Void, Never>?

    init(coordinator: PetsCoordinator) {
        self.coordinator = coordinator
        super.init()
        configurePopover()
    }

    /// Bring the panel on screen at the persisted position
    /// (or the default top-right corner on first launch).
    func show() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }
        positionPanelFromSettings(panel)
        panel.orderFrontRegardless()
    }

    /// Take the panel off screen but keep the controller around
    /// so re-show is fast (no rebuild).
    func hide() {
        panel?.orderOut(nil)
        popover.performClose(nil)
    }

    /// Re-apply the persisted position from `PetsPreferences`.
    /// Called when the corner picker changes or whenever the
    /// caller wants the panel to snap back to its declared spot.
    func reposition() {
        guard let panel else { return }
        positionPanelFromSettings(panel)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let root = PetsFloatingPanelRoot(
            controller: self,
            coordinator: coordinator
        )
        let hostingController = NSHostingController(rootView: root)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary  // visible even over fullscreen apps
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false   // we drive moves manually

        self.panel = panel
        self.hosting = hostingController
    }

    private func positionPanelFromSettings(_ panel: NSPanel) {
        PetsPreferencesStore.shared.loadIfNeeded()
        let pets = PetsPreferencesStore.shared.current
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let screenFrame = screen.visibleFrame

        // If we have an explicit (positionX, positionY) > 0
        // saved, honour it; otherwise lay out by corner.
        if pets.positionX > 0 || pets.positionY > 0 {
            let origin = NSPoint(x: pets.positionX, y: pets.positionY)
            panel.setFrameOrigin(clampToScreen(origin, frame: frame, screen: screenFrame))
            return
        }

        let inset: CGFloat = 24
        switch pets.corner {
        case "topLeft":
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.minX + inset,
                y: screenFrame.maxY - frame.height - inset
            ))
        case "bottomLeft":
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.minX + inset,
                y: screenFrame.minY + inset
            ))
        case "bottomRight":
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.maxX - frame.width - inset,
                y: screenFrame.minY + inset
            ))
        default:    // topRight
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.maxX - frame.width - inset,
                y: screenFrame.maxY - frame.height - inset
            ))
        }
    }

    private func clampToScreen(_ origin: NSPoint, frame: NSRect, screen: NSRect) -> NSPoint {
        var p = origin
        p.x = max(screen.minX, min(p.x, screen.maxX - frame.width))
        p.y = max(screen.minY, min(p.y, screen.maxY - frame.height))
        return p
    }

    // MARK: - Drag handling

    /// Called from `PetSpriteView`'s drag gesture every frame.
    /// Apply the delta synchronously (no animation) so the pet
    /// tracks the cursor 1:1.
    func dragPanel(by delta: CGSize) {
        guard let panel,
              let screen = NSScreen.main else { return }
        var origin = panel.frame.origin
        // SwiftUI drag deltas are in down-positive screen coords;
        // AppKit window origins are up-positive. Flip Y.
        origin.x += delta.width
        origin.y -= delta.height
        origin = clampToScreen(origin, frame: panel.frame, screen: screen.visibleFrame)
        panel.setFrameOrigin(origin)
    }

    /// Persist the panel's current position to settings, with
    /// a small debounce so a long drag only writes once.
    func saveDragEnd() {
        guard let panel else { return }
        let origin = panel.frame.origin
        saveDebounce?.cancel()
        saveDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            PetsPreferencesStore.shared.update { prefs in
                prefs.positionX = Double(origin.x)
                prefs.positionY = Double(origin.y)
            }
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient   // close on click-outside
        popover.animates = true
    }

    /// Show the click-to-expand popover anchored to the sprite.
    func toggleExpandedPopover(anchor: NSView) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let coordinator else { return }
        let view = PetsExpandedPopoverView(
            coordinator: coordinator,
            onCloseRequested: { [weak self] in
                self?.popover.performClose(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Double-click on the sprite. If liveAgent is on, opens a
    /// small input popover that tado-sends the user's text to
    /// the companion tile. If liveAgent is off, surface a
    /// banner pointing to Settings.
    func toggleLiveAgentPrompt() {
        guard let coordinator, let host = hostingView else { return }
        if popover.isShown { popover.performClose(nil) }
        let prefs = PetsPreferencesStore.shared.current
        guard prefs.liveAgent else {
            EventBus.shared.publish(
                TadoEvent(
                    type: "user.broadcast",
                    severity: .info,
                    source: .system,
                    title: "Live agent is off",
                    body: "Open Pets settings → Live agent companion to enable."
                )
            )
            return
        }
        let view = PetsLiveAgentPromptView(
            sessionID: prefs.liveAgentSessionID,
            onSend: { [weak self, weak coordinator] text in
                coordinator?.sendToLiveCompanion(text)
                self?.popover.performClose(nil)
            },
            onCancel: { [weak self] in
                self?.popover.performClose(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 320, height: 132)
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
    }
}

/// Tiny SwiftUI view used by `toggleLiveAgentPrompt`. Single
/// text field + Send / Cancel. Cmd+Enter / Return submits.
private struct PetsLiveAgentPromptView: View {
    let sessionID: String?
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talk to your pet companion")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if let id = sessionID {
                Text("Tile \(id.prefix(8))…")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospaced()
            } else {
                Text("Companion tile is starting up — your message will queue.")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow.opacity(0.85))
            }
            TextField(
                "e.g. \"intervene on tile 1,1 and ask it to switch to typescript\"",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
            .focused($focused)
            .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color.black.opacity(0.92))
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}

/// Root SwiftUI view of the floating panel. Reads
/// `PetsCoordinator.aggregate` and renders the sprite.
///
/// Why a separate type — `PetsFloatingPanelController` needs a
/// concrete `View` for the `NSHostingController` generic, and we
/// want the view to capture the controller weakly so the panel
/// can survive view rebuilds.
struct PetsFloatingPanelRoot: View {
    weak var controller: PetsFloatingPanelController?
    let coordinator: PetsCoordinator?

    @State private var anchorView = NSView()

    var body: some View {
        Group {
            if let coordinator {
                // Read directly off `coordinator.petSettings` so
                // SwiftUI tracks the @Observable property and
                // re-renders when the settings sheet, the /pet
                // slash command, or the Pets settings window
                // flips a value. Reading from
                // `PetsPreferencesStore.shared.current` here
                // would snapshot at body-build time and miss
                // every subsequent change.
                let pets = coordinator.petSettings
                PetSpriteView(
                    petID: pets.pet,
                    state: coordinator.aggregate.state,
                    bubble: pets.showThoughtBubble ? coordinator.aggregate.bubble : nil,
                    badgeCount: coordinator.aggregate.totalNeedsInput,
                    onTap: { [weak controller] in
                        if let host = controller?.hostingView {
                            controller?.toggleExpandedPopover(anchor: host)
                        }
                    },
                    onDoubleTap: { [weak controller] in
                        controller?.toggleLiveAgentPrompt()
                    },
                    onDrag: { [weak controller] delta in
                        controller?.dragPanel(by: delta)
                    },
                    onDragEnd: { [weak controller] in
                        controller?.saveDragEnd()
                    }
                )
                .opacity(pets.opacity)
            } else {
                EmptyView()
            }
        }
        .frame(width: 140, height: 160, alignment: .bottomLeading)
        .background(Color.clear)
    }
}

extension PetsFloatingPanelController {
    /// Public accessor used by the SwiftUI root to hand
    /// `toggleExpandedPopover` an AppKit anchor view.
    var hostingView: NSView? {
        hosting?.view
    }
}
