// Phase 14 — terracotta focus ring per brief section 2.8.
//
// Every interactive Relay primitive carries `.relayFocusRing()` so
// keyboard focus paints a 2px terracotta outline + 2px offset.
// The brief insists "Never remove focus styles."
//
// SwiftUI provides `:focus-visible` semantics through
// `@FocusState` — bind a Bool to `.focused($flag)` and toggle the
// outline based on it. The modifier here is sugar that produces a
// fixed-shape outline. Reduce-motion users see the same ring (it's
// a static stroke, not an animation).

import SwiftUI

struct RelayFocusRingModifier: ViewModifier {
    let isFocused: Bool
    var radius: CGFloat = RelayRadius.standard

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                    .stroke(
                        isFocused ? RelayPalette.terracotta : Color.clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
    }
}

extension View {
    /// Apply the Relay focus ring (2px terracotta outline + 2px
    /// offset) when the bound `@FocusState` Bool is true. Use the
    /// matching corner radius — defaults to the standard 5.5pt.
    func relayFocusRing(_ isFocused: Bool, radius: CGFloat = RelayRadius.standard) -> some View {
        modifier(RelayFocusRingModifier(isFocused: isFocused, radius: radius))
    }
}
