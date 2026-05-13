import Foundation
import CoreGraphics

/// Hand-rolled force-directed layout used by the Knowledge → Graph
/// surface when the Rust-side layout cache is empty or stale.
///
/// Three forces:
///   - **Repulsion** between every pair of nodes (Coulomb-like, 1/r²),
///     soft-clamped to keep tight clusters from exploding.
///   - **Attraction** along edges (Hooke spring toward target length).
///   - **Gravity** toward `(0, 0)` so the graph doesn't drift off the
///     canvas on disconnected components.
///
/// Convergence is measured as the sum of |Δposition| across all nodes
/// per iteration; when it falls below `convergenceThreshold` the
/// runner returns. Caps `maxIterations` so a pathological input still
/// terminates within the brief's 3-second budget on 500 nodes.
struct ForceLayout {

    struct Node: Equatable {
        let id: String
        var position: CGPoint
        var velocity: CGVector

        init(id: String, position: CGPoint, velocity: CGVector = .zero) {
            self.id = id
            self.position = position
            self.velocity = velocity
        }
    }

    struct Edge: Equatable {
        let source: String
        let target: String
    }

    struct Config: Equatable {
        var repulsion: Double = 1_500
        var springLength: Double = 80
        var springStiffness: Double = 0.05
        var gravity: Double = 0.01
        var damping: Double = 0.85
        var maxIterations: Int = 250
        var convergenceThreshold: Double = 0.5
    }

    struct Outcome: Equatable {
        var iterations: Int
        var converged: Bool
        var nodes: [Node]
    }

    /// Run the layout to convergence (or `maxIterations`, whichever
    /// fires first). Pure: no logging, no Dispatch, no Combine. The
    /// P3 acceptance harness times this on 500 nodes / 750 edges.
    static func run(
        nodes: [Node],
        edges: [Edge],
        config: Config = Config()
    ) -> Outcome {
        var nodes = nodes
        let indexByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) }
        )

        var converged = false
        var lastIteration = 0
        for iter in 0..<config.maxIterations {
            lastIteration = iter + 1
            // Repulsion (O(n²)). 500 nodes → 250k pair operations per
            // iter; small constant per pair keeps us well under budget.
            var forces = [CGVector](repeating: .zero, count: nodes.count)
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let dx = nodes[i].position.x - nodes[j].position.x
                    let dy = nodes[i].position.y - nodes[j].position.y
                    var distSq = dx * dx + dy * dy
                    if distSq < 0.01 { distSq = 0.01 }
                    let dist = sqrt(distSq)
                    let force = config.repulsion / distSq
                    let fx = force * dx / dist
                    let fy = force * dy / dist
                    forces[i].dx += fx
                    forces[i].dy += fy
                    forces[j].dx -= fx
                    forces[j].dy -= fy
                }
            }

            // Spring attraction along edges.
            for edge in edges {
                guard let s = indexByID[edge.source], let t = indexByID[edge.target] else { continue }
                let dx = nodes[t].position.x - nodes[s].position.x
                let dy = nodes[t].position.y - nodes[s].position.y
                var dist = sqrt(dx * dx + dy * dy)
                if dist < 0.01 { dist = 0.01 }
                let displacement = dist - config.springLength
                let force = config.springStiffness * displacement
                let fx = force * dx / dist
                let fy = force * dy / dist
                forces[s].dx += fx; forces[s].dy += fy
                forces[t].dx -= fx; forces[t].dy -= fy
            }

            // Gravity toward origin.
            for i in 0..<nodes.count {
                forces[i].dx -= config.gravity * Double(nodes[i].position.x)
                forces[i].dy -= config.gravity * Double(nodes[i].position.y)
            }

            // Integrate.
            var totalDelta = 0.0
            for i in 0..<nodes.count {
                nodes[i].velocity.dx = (nodes[i].velocity.dx + forces[i].dx) * config.damping
                nodes[i].velocity.dy = (nodes[i].velocity.dy + forces[i].dy) * config.damping
                let dx = nodes[i].velocity.dx
                let dy = nodes[i].velocity.dy
                nodes[i].position.x += dx
                nodes[i].position.y += dy
                totalDelta += abs(Double(dx)) + abs(Double(dy))
            }

            if totalDelta / max(1.0, Double(nodes.count)) < config.convergenceThreshold {
                converged = true
                break
            }
        }

        return Outcome(iterations: lastIteration, converged: converged, nodes: nodes)
    }
}
