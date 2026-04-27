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
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Text(crumb.label)
                        .font(Typography.caption)
                        .foregroundStyle(idx == crumbs.count - 1 ? Palette.textPrimary : Palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Breadcrumb: \(crumbs.map(\.label).joined(separator: " in "))")
        }
    }
}
