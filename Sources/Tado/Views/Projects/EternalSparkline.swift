import SwiftUI

/// Minimalist line sparkline over the last N numeric samples. Used by the
/// Eternal section's running card to show the metric history across
/// Sprint-mode runs.
///
/// Non-numeric or empty inputs render as a subtle baseline so the component
/// never disappears while metrics are still loading — the user sees "a chart
/// is coming", not blank air.
struct EternalSparkline: View {
    /// Samples in oldest → newest order. Each sample is one Sprint's metric.
    let values: [Double]
    var lineColor: Color = Palette.accent
    var fillColor: Color = Palette.accent.opacity(0.18)
    /// If true, render a tiny dot at the latest point so the current value is
    /// obviously distinguishable from the curve.
    var markLast: Bool = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if values.count >= 2 {
                    let pts = scaledPoints(width: w, height: h)

                    // Fill under the line so a rising trend reads at a glance.
                    Path { p in
                        guard let first = pts.first, let last = pts.last else { return }
                        p.move(to: CGPoint(x: first.x, y: h))
                        p.addLine(to: first)
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: last.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(fillColor)

                    // The line.
                    Path { p in
                        guard let first = pts.first else { return }
                        p.move(to: first)
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

                    if markLast, let last = pts.last {
                        Circle()
                            .fill(lineColor)
                            .frame(width: 4, height: 4)
                            .position(x: last.x, y: last.y)
                    }
                } else {
                    // Baseline so the component never collapses to zero height
                    // visually while samples are still accumulating.
                    Rectangle()
                        .fill(Palette.divider)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .offset(y: h / 2 - 0.5)
                }
            }
        }
    }

    private func scaledPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let span = max(maxV - minV, 0.0001)   // avoid /0 on a flat series
        let dx = width / CGFloat(max(values.count - 1, 1))
        let insetTop: CGFloat = 2
        let insetBottom: CGFloat = 2
        let usableH = max(1, height - insetTop - insetBottom)

        return values.enumerated().map { (i, v) in
            let x = CGFloat(i) * dx
            let normalised = (v - minV) / span
            // Flip — higher value = higher on screen (smaller y).
            let y = insetTop + usableH * CGFloat(1 - normalised)
            return CGPoint(x: x, y: y)
        }
    }
}
