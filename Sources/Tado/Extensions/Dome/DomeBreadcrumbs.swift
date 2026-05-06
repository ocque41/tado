import SwiftUI

/// Pure-Swift breadcrumb resolver for the Dome window. P6 brief calls
/// for "navigation breadcrumbs" — this lifts the trail computation
/// out of the SwiftUI view so the perf-budget harness can pin it.
///
/// Breadcrumb chain shape: `Dome › <surface> [ › <subpage>]`. The
/// resolver returns an array of segments so the renderer can decide
/// styling (active vs inactive, separator chevrons).
enum DomeBreadcrumbs {

    struct Crumb: Equatable {
        let label: String
        let identifier: String
    }

    static func trail(
        for surface: DomeSurfaceTab,
        knowledgePage: DomeKnowledgePage? = nil,
        scope: DomeScopeSelection? = nil
    ) -> [Crumb] {
        var crumbs: [Crumb] = [Crumb(label: "Dome", identifier: "dome")]
        if let scope, case .project(_, let name, _, _) = scope {
            crumbs.append(Crumb(label: name, identifier: "scope.project"))
        }
        crumbs.append(Crumb(label: surface.label, identifier: "surface.\(surface.rawValue)"))
        if surface == .knowledge, let page = knowledgePage {
            crumbs.append(Crumb(label: page.label, identifier: "knowledge.\(page.rawValue)"))
        }
        return crumbs
    }
}

/// Inline view for the trail. Zero state — pulls from the supplied
/// crumbs and stays hidden when there's only the root.
///
/// v0.18: rebuilt on the structural-grid type stack — mono caption
/// for every crumb, ink3 chevron separator, ink for the active
/// (final) crumb, ink2 for prior segments. Keeps the same shape
/// (no border, no fill) so it slots into the topbar without
/// stealing visual weight from the scope picker.
struct DomeBreadcrumbsView: View {
    let crumbs: [DomeBreadcrumbs.Crumb]

    var body: some View {
        if crumbs.count <= 1 {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.element.identifier) { idx, crumb in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.ink4)
                    }
                    Text(crumb.label)
                        .font(Typography.monoCaption)
                        .foregroundStyle(idx == crumbs.count - 1 ? Palette.ink : Palette.ink3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Breadcrumb: \(crumbs.map(\.label).joined(separator: " in "))")
        }
    }
}
