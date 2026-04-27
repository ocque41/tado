import SwiftUI
import AppKit

/// Wraps `Content` in browser-style zoom: lays out the body at
/// `windowSize / zoom`, then scales back up via `scaleEffect`. Content
/// always fills the window AND respects the current zoom — same model
/// Safari/Chrome use, and what makes corner-drag-resize feel responsive
/// at every zoom level.
struct WindowZoomScaler<Content: View>: View {
    let zoomState: WindowZoomState
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let safeZoom = max(zoomState.zoom, 0.01)
            // `ceil` on the logical size keeps the scaled output covering
            // the window edge-to-edge at every zoom — without it,
            // floating-point rounding leaves a hairline gap on the
            // bottom/right when the window is dragged to extreme sizes.
            let logicalWidth = max(1, ceil(proxy.size.width / safeZoom))
            let logicalHeight = max(1, ceil(proxy.size.height / safeZoom))
            content()
                .frame(width: logicalWidth, height: logicalHeight)
                .scaleEffect(safeZoom, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

/// Window-scoped Cmd/Ctrl + / − / 0 keyboard handler. Mirrors
/// `CanvasWindowProbe` (+ canvas keyMonitor) elsewhere in the app:
/// captures `NSWindow.windowNumber` on first attach and only consumes
/// events whose `event.window` matches that exact window — so each
/// `WindowGroup` zooms independently with no cross-window leakage.
struct WindowZoomKeyMonitor: NSViewRepresentable {
    let zoomState: WindowZoomState
    let shouldIntercept: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.zoomState = zoomState
        view.shouldIntercept = shouldIntercept
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.zoomState = zoomState
        view.shouldIntercept = shouldIntercept
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MonitorView)?.tearDown()
    }

    @MainActor
    private final class MonitorView: NSView {
        var zoomState: WindowZoomState?
        var shouldIntercept: (() -> Bool)?
        private var hostWindowNumber: Int?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hostWindowNumber = window?.windowNumber
            installMonitorIfNeeded()
        }

        func tearDown() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let zoomState = self.zoomState else { return event }
                guard event.window?.windowNumber == self.hostWindowNumber else { return event }
                if let predicate = self.shouldIntercept, !predicate() { return event }
                let mods = event.modifierFlags
                guard mods.contains(.command) || mods.contains(.control) else { return event }
                // Auto-repeat (holding the key) MUST NOT animate — every
                // queued keystroke would stack a 60-80ms easeOut on top of
                // the previous one and the result is laggy stutter. Use
                // animation only for the initial press, then drop into
                // direct mutation for repeats. Result: holding zooms
                // smoothly at the OS auto-repeat rate.
                let useAnimation = !event.isARepeat
                let apply: (() -> Void) -> Void = { mutation in
                    if useAnimation {
                        withAnimation(.easeOut(duration: 0.06)) { mutation() }
                    } else {
                        mutation()
                    }
                }
                switch event.charactersIgnoringModifiers {
                case "=", "+":
                    apply { zoomState.zoomIn() }
                    return nil
                case "-":
                    apply { zoomState.zoomOut() }
                    return nil
                case "0":
                    apply { zoomState.reset() }
                    return nil
                default:
                    return event
                }
            }
        }
    }
}

extension View {
    /// Apply browser-style zoom and Cmd/Ctrl+= / -- / 0 handling to this
    /// view's window. `shouldIntercept` gates the keyboard handler — used
    /// on the main window to defer Cmd+/-/0 to the canvas's own zoom
    /// handler while the canvas page is visible.
    func windowZoom(
        _ state: WindowZoomState,
        shouldIntercept: @escaping () -> Bool = { true }
    ) -> some View {
        WindowZoomScaler(zoomState: state) { self }
            .background(WindowZoomKeyMonitor(zoomState: state, shouldIntercept: shouldIntercept))
    }
}
